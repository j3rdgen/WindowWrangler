//
//  BoundedConcurrentMap.swift
//  Window Wrangler
//
//  Generic Swift-concurrency helper: apply an async transform to every
//  element of an input array with a bounded worker pool, returning
//  results in the original input order.
//
//  Extracted from the All-Apps Cascade path — the concrete use case is
//  running `AXWindowEnumerator.windows(of:)` concurrently across every
//  eligible running app, subject to a bounded worker pool that keeps
//  the number of simultaneous cross-process AX round-trips small.
//
//  Kept generic so the primitive is unit-testable with fake work
//  (no live AX or main-actor scaffolding required).
//

import Foundation

/// Instrumentation counters produced by `BoundedConcurrentMap.mapWithMetrics`.
/// Used by the All-Apps Cascade path to prove that the bounded worker pool is
/// actually running workers in parallel (guarding against hidden serialization
/// from an actor / dispatch queue) and to surface per-item durations so slow
/// AX enumerations can be identified by name in the log.
///
/// Correctness of the primitive itself is proven by `map`'s tests; these
/// metrics are diagnostic-only and never influence result ordering or count.
struct BoundedConcurrentMapMetrics {
    /// Highest simultaneous in-flight worker count observed across the run.
    /// Should approach `min(inputs.count, maxConcurrency)` when the transform
    /// takes any real time — a value of 1 with many inputs is evidence of a
    /// hidden serialization point (actor boundary, main-thread dispatch,
    /// serial DispatchQueue).
    let maxObservedInFlight: Int
    /// One duration per input, in the same index order as the results array.
    /// `perItemDurationSeconds[i]` is the wall-clock time spent inside the
    /// caller's `transform` for `inputs[i]` (does not include time queued
    /// waiting for a worker slot).
    let perItemDurationSeconds: [Double]
}

/// Internal thread-safe in-flight counter for `mapWithMetrics`. Kept
/// file-private and `@unchecked Sendable` — mutation only occurs under the
/// `NSLock`, and the two `Int` fields have no unsafe stored properties.
/// Same shape as the counter in `BoundedConcurrentMapTests` so the primitive
/// and the test share one auditable pattern.
private final class InFlightMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int = 0
    private var peak: Int = 0

    func enter() {
        lock.lock()
        current += 1
        if current > peak { peak = current }
        lock.unlock()
    }
    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
    var peakInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

enum BoundedConcurrentMap {

    /// Applies `transform` to every element of `inputs` concurrently,
    /// with at most `maxConcurrency` transforms running at any moment.
    /// Returns results in the original input order.
    ///
    /// Uses `withTaskGroup` with a prime-and-refill scheduler: primes
    /// `maxConcurrency` workers, then starts one new worker for each
    /// completed one, so the in-flight count never exceeds the bound.
    /// Results are collected into a pre-sized array indexed by the
    /// input position — safe without a lock because `TaskGroup.next()`
    /// serializes result delivery on the caller.
    ///
    /// Guarantees:
    ///   - Every input produces exactly one output in the same position.
    ///   - Order is deterministic regardless of task-completion order.
    ///   - Maximum in-flight tasks == min(inputs.count, maxConcurrency).
    ///   - Empty input returns an empty array.
    ///   - `maxConcurrency` ≤ 0 is treated as 1 (defensive).
    ///
    /// - Parameters:
    ///   - inputs: The values to transform, in the order results are
    ///     expected. `Sendable` because each is captured by a Task
    ///     closure that runs off the caller's actor.
    ///   - maxConcurrency: Upper bound on simultaneous in-flight
    ///     transforms. Bounded by `inputs.count` internally — no
    ///     wasted worker slots for tiny inputs.
    ///   - transform: The async work to run for each input. `@Sendable`
    ///     because it runs on the cooperative concurrent executor.
    ///
    /// - Returns: `[Output]` with `output[i] = await transform(inputs[i])`.
    static func map<Input, Output>(
        _ inputs: [Input],
        maxConcurrency: Int,
        transform: @Sendable @escaping (Input) async -> Output
    ) async -> [Output] where Input: Sendable, Output: Sendable {
        guard !inputs.isEmpty else { return [] }
        let bound = max(1, min(maxConcurrency, inputs.count))
        var results: [Output?] = Array(repeating: nil, count: inputs.count)

        await withTaskGroup(of: (Int, Output).self) { group in
            var iter = inputs.enumerated().makeIterator()

            // Prime up to `bound` workers.
            for _ in 0..<bound {
                guard let (idx, input) = iter.next() else { break }
                group.addTask {
                    (idx, await transform(input))
                }
            }

            // As each task completes, start the next queued input.
            // `group.next()` serializes delivery — no lock needed on
            // `results` because only this loop writes to it.
            while let (idx, output) = await group.next() {
                results[idx] = output
                if let (nextIdx, nextInput) = iter.next() {
                    group.addTask {
                        (nextIdx, await transform(nextInput))
                    }
                }
            }
        }

        // Every slot is guaranteed populated by the invariant above —
        // `guard let` would be a needless force-unwrap dance.
        return results.compactMap { $0 }
    }

    /// Same contract as `map`, plus diagnostic `metrics` describing the
    /// actual runtime concurrency and per-item wall-clock durations.
    /// Used by the All-Apps Cascade enumeration path — the metrics let the
    /// log line answer "did we actually parallelize, and which apps are
    /// slow?" without a second traversal.
    ///
    /// Overhead vs. `map`: one atomic-under-lock counter enter/exit per
    /// item plus two `CFAbsoluteTimeGetCurrent()` calls per item. Both are
    /// negligible next to a cross-process AX round-trip.
    static func mapWithMetrics<Input, Output>(
        _ inputs: [Input],
        maxConcurrency: Int,
        transform: @Sendable @escaping (Input) async -> Output
    ) async -> (results: [Output], metrics: BoundedConcurrentMapMetrics)
    where Input: Sendable, Output: Sendable {
        guard !inputs.isEmpty else {
            return ([], BoundedConcurrentMapMetrics(maxObservedInFlight: 0, perItemDurationSeconds: []))
        }
        let bound = max(1, min(maxConcurrency, inputs.count))
        var results: [Output?] = Array(repeating: nil, count: inputs.count)
        var durations: [Double] = Array(repeating: 0, count: inputs.count)
        let meter = InFlightMeter()

        await withTaskGroup(of: (Int, Output, Double).self) { group in
            var iter = inputs.enumerated().makeIterator()

            for _ in 0..<bound {
                guard let (idx, input) = iter.next() else { break }
                group.addTask {
                    meter.enter()
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let output = await transform(input)
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    meter.exit()
                    return (idx, output, elapsed)
                }
            }

            while let (idx, output, elapsed) = await group.next() {
                results[idx] = output
                durations[idx] = elapsed
                if let (nextIdx, nextInput) = iter.next() {
                    group.addTask {
                        meter.enter()
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let output = await transform(nextInput)
                        let elapsed = CFAbsoluteTimeGetCurrent() - t0
                        meter.exit()
                        return (nextIdx, output, elapsed)
                    }
                }
            }
        }

        let metrics = BoundedConcurrentMapMetrics(
            maxObservedInFlight: meter.peakInFlight,
            perItemDurationSeconds: durations
        )
        return (results.compactMap { $0 }, metrics)
    }
}
