//
//  CGWindowSnapshotTests.swift
//  Window WranglerTests
//
//  Tests the failure-vs-empty-success distinction of the CG snapshot
//  wrapper used by the accessory CG-negative prefilter. The live
//  `CGWindowSnapshotter.snapshot()` call is exercised in a minimal
//  smoke test (macOS always has WindowServer running in test host);
//  the failure branch has no unit-testable live surface, so we test
//  it structurally on the enum shape.
//

import XCTest
@testable import Window_Wrangler

final class CGWindowSnapshotTests: XCTestCase {

    /// Live smoke: on a running test host, CG always succeeds and
    /// returns at least one owning PID (the test runner itself owns
    /// at least an XCTest-hosted window / mach-o process visible to
    /// CG). Proves the shape and non-crash behavior on real CG data.
    func test_liveSnapshot_returnsSuccessWithSomePIDs() {
        let snapshot = CGWindowSnapshotter.snapshot()
        switch snapshot {
        case .success(let pids):
            // Absence of CG on the host would be a test-infra bug —
            // fail loudly rather than silently accepting empty.
            XCTAssertGreaterThan(pids.count, 0,
                "Live CG snapshot returned empty on running test host — CG API unexpectedly not returning any windows.")
        case .failure:
            XCTFail("Live CG snapshot returned .failure on a running host — CG API expected to succeed.")
        }
    }

    /// The `.pids` computed accessor returns Some(set) on success and
    /// nil on failure — this is the exact discriminator the prefilter
    /// uses to decide fail-open vs fail-open-safe.
    func test_pidsAccessor_discriminatesSuccessFromFailure() {
        let success = CGWindowSnapshot.success(pidsWithAnyWindow: [1, 2, 3])
        let failure = CGWindowSnapshot.failure
        XCTAssertEqual(success.pids, Set([1, 2, 3]))
        XCTAssertNil(failure.pids,
            "Failure must be distinguishable from success-with-empty via the .pids accessor.")
    }

    /// Successful-empty is a valid state (WindowServer running with no
    /// windows returned by our option set). Must be Some(empty), not nil.
    func test_successfulEmpty_isDistinguishableFromFailure() {
        let empty = CGWindowSnapshot.success(pidsWithAnyWindow: [])
        XCTAssertNotNil(empty.pids)
        XCTAssertEqual(empty.pids?.count, 0)
    }
}
