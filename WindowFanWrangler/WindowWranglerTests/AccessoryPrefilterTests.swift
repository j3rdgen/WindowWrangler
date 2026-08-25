//
//  AccessoryPrefilterTests.swift
//  Window WranglerTests
//
//  Tests the pure classification function that decides which apps get
//  AX-enumerated and which are skipped under the accessory CG-negative
//  prefilter. Covers Part 4 §Test 1-16 of the reaction-time
//  optimization specification: regular apps are always AX regardless
//  of CG state, accessory apps with any CG entry are AX, accessory
//  apps without any CG entry are skipped, CG failure fails open,
//  bypass set always AX, deterministic order preserved, filter counts
//  correct on realistic-scale inputs.
//

import AppKit
import XCTest
@testable import Window_Wrangler

final class AccessoryPrefilterTests: XCTestCase {

    // MARK: - Fixtures

    private typealias Facts = CascadeOrchestrator.PrefilterAppFacts

    private func regular(pid: pid_t, bundle: String = "com.example.regular") -> Facts {
        Facts(pid: pid, bundleID: bundle, policy: .regular)
    }
    private func accessory(pid: pid_t, bundle: String = "com.example.accessory") -> Facts {
        Facts(pid: pid, bundleID: bundle, policy: .accessory)
    }

    // MARK: - Test 1: Regular CG-negative → always AX (blind-spot protection)

    /// A `.regular` app whose PID is absent from a SUCCESSFUL CG
    /// snapshot must still be AX-enumerated. This is the Notes /
    /// Podcasts / Grammarly protection — those apps can own AX-visible
    /// windows that CGWindowList does not report.
    func test_regularCGNegative_alwaysAX() {
        let apps = [regular(pid: 100)]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [.some(100)])
        XCTAssertEqual(result.regularCount, 1)
        XCTAssertEqual(result.accessoryCount, 0)
        XCTAssertEqual(result.axEnumeratedCount, 1)
    }

    // MARK: - Test 2: Regular CG-positive → AX (CG presence isn't authoritative)

    func test_regularCGPositive_alsoAX() {
        let apps = [regular(pid: 100)]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [100])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [.some(100)])
        XCTAssertEqual(result.regularCount, 1)
    }

    // MARK: - Test 3: Accessory CG-positive → AX

    func test_accessoryCGPositive_AX() {
        let apps = [accessory(pid: 200)]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [200])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [.some(200)])
        XCTAssertEqual(result.accessoryCount, 1)
        XCTAssertEqual(result.accessoryCGPositiveCount, 1)
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 0)
    }

    // MARK: - Test 4: Accessory CG-negative + successful snapshot → skip

    func test_accessoryCGNegative_successfulSnapshot_skip() {
        let apps = [accessory(pid: 300)]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [999])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [.none])
        XCTAssertEqual(result.accessoryCount, 1)
        XCTAssertEqual(result.accessoryCGPositiveCount, 0)
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 1)
        XCTAssertEqual(result.axEnumeratedCount, 0)
    }

    // MARK: - Test 5: The design-assumption test (documents the residual risk)

    /// If an `.accessory` app owns a legitimate window that CGWindowList
    /// does not report, the classifier WILL skip it. That is the
    /// documented Path A risk. This test makes the assumption
    /// explicit: verify that the ONLY escape hatches are the feature
    /// flag off (tested elsewhere) or the bypass set (Test 8). If the
    /// product ever requires zero theoretical membership regressions,
    /// the correct fix is to disable the prefilter, not amend this test.
    func test_hypotheticalAccessoryWithInvisibleCGWindow_isSkipped() {
        // The hypothetical app owns a real AX-visible window that
        // never appears in CGWindowList (blind-spot).
        let apps = [accessory(pid: 400, bundle: "com.hypothetical.invisible")]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        // Documented behavior — the skip WILL happen.
        XCTAssertEqual(result.pidsForAXCall, [.none],
            "Path A skips accessory apps with CG-invisible windows. If this ever hurts a real app, add its bundle ID to accessoryAppsAlwaysAXEnumerated.")
        // The escape hatch works:
        let withBypass = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap,
            bypassSet: ["com.hypothetical.invisible"]
        )
        XCTAssertEqual(withBypass.pidsForAXCall, [.some(400)])
    }

    // MARK: - Test 6: CG snapshot failure → fail open (all AX)

    func test_cgFailure_failsOpen_allEnumerated() {
        let apps = [
            regular(pid: 100),
            accessory(pid: 200),
            accessory(pid: 300),
        ]
        let snap: CGWindowSnapshot = .failure
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall,
                       [.some(100), .some(200), .some(300)],
            "CG failure must NOT cause mass skipping — every accessory must fall back to AX.")
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 0)
    }

    // MARK: - Test 7: Empty successful snapshot DIFFERS from failure

    /// A successful empty snapshot MUST drive skipping of accessory
    /// apps; only failure fails open. This distinguishes the two
    /// downstream behaviors that the `CGWindowSnapshot.pids` accessor
    /// discriminates.
    func test_emptySuccessfulSnapshot_skipsAccessoriesUnlikeFailure() {
        let apps = [accessory(pid: 200)]
        let emptySuccess: CGWindowSnapshot = .success(pidsWithAnyWindow: [])
        let failure: CGWindowSnapshot = .failure

        let emptyResult = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: emptySuccess, bypassSet: []
        )
        let failResult = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: failure, bypassSet: []
        )
        XCTAssertEqual(emptyResult.pidsForAXCall, [.none])
        XCTAssertEqual(failResult.pidsForAXCall, [.some(200)])
    }

    // MARK: - Test 8: Bypass set overrides skip

    func test_bypassSet_overridesSkipEvenWhenCGNegative() {
        let apps = [accessory(pid: 500, bundle: "com.mustAX.helper")]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [])  // CG-negative
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: ["com.mustAX.helper"]
        )
        XCTAssertEqual(result.pidsForAXCall, [.some(500)])
        XCTAssertEqual(result.accessoryBypassedCount, 1)
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 0)
    }

    // MARK: - Test 11: Realistic filter-count fixture

    /// Mirrors the spec's example: 71 eligible = 31 regular + 40
    /// accessory (6 CG-positive + 34 CG-negative). Expected AX
    /// candidate count = 31 + 6 = 37.
    func test_realisticFilterCounts_matchSpecExample() {
        var apps: [Facts] = []
        for i in 0..<31 { apps.append(regular(pid: pid_t(1000 + i))) }
        // 6 CG-positive accessories
        for i in 0..<6 { apps.append(accessory(pid: pid_t(2000 + i))) }
        // 34 CG-negative accessories
        for i in 0..<34 { apps.append(accessory(pid: pid_t(3000 + i))) }

        let cgPIDs: Set<pid_t> = Set((2000..<2006).map { pid_t($0) })
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: cgPIDs)
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.regularCount, 31)
        XCTAssertEqual(result.accessoryCount, 40)
        XCTAssertEqual(result.accessoryCGPositiveCount, 6)
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 34)
        XCTAssertEqual(result.axEnumeratedCount, 37)
        XCTAssertEqual(result.pidsForAXCall.count, 71,
            "Output array must be index-aligned with input apps.")
    }

    // MARK: - Test 12: Deterministic order preservation

    /// Input order must survive the classifier. CG PID iteration order
    /// must not leak into the output (Cascade determinism depends on
    /// the caller's original ordering: frontmost-first + alphabetical).
    func test_deterministicOrder_preservedRegardlessOfCGPIDOrder() {
        let apps = [
            regular(pid: 10),
            accessory(pid: 20),  // CG-positive
            regular(pid: 30),
            accessory(pid: 40),  // CG-negative
            accessory(pid: 50),  // CG-positive
        ]
        // CG set contains 20 and 50, in whatever internal order.
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [50, 20, 999])
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall,
                       [.some(10), .some(20), .some(30), .none, .some(50)])
    }

    // MARK: - Test 16: Many accessory helpers drops most, keeps CG-positive

    /// Models the 40-accessory-app fixture: 35 CG-negative helpers get
    /// skipped, 5 CG-positive remain in the AX candidate set.
    func test_manyAccessoryHelpers_skipsCGNegativeKeepsCGPositive() {
        var apps: [Facts] = []
        for i in 0..<35 { apps.append(accessory(pid: pid_t(4000 + i))) }  // CG-negative
        for i in 0..<5  { apps.append(accessory(pid: pid_t(5000 + i))) }  // CG-positive
        let cgPIDs: Set<pid_t> = Set((5000..<5005).map { pid_t($0) })
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: cgPIDs)
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 35)
        XCTAssertEqual(result.accessoryCGPositiveCount, 5)
        XCTAssertEqual(result.axEnumeratedCount, 5)
    }

    // MARK: - Test 15: Known blind-spot regular apps stay in even CG-negative

    /// Mock representation of the Catalyst / overlay problem apps —
    /// their `.regular` classification is what protects them. Test
    /// with a CG-empty snapshot to prove no regular app is ever skipped.
    func test_knownBlindSpotRegularApps_alwaysAXEvenIfCGNegative() {
        let apps = [
            regular(pid: 700, bundle: "com.apple.Notes"),
            regular(pid: 701, bundle: "com.apple.podcasts"),
            regular(pid: 702, bundle: "com.grammarly.ProjectLlama"),
        ]
        let snap: CGWindowSnapshot = .success(pidsWithAnyWindow: [])  // all CG-negative
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: apps, cgSnapshot: snap, bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall,
                       [.some(700), .some(701), .some(702)])
        XCTAssertEqual(result.accessorySkippedCGNegativeCount, 0)
    }

    // MARK: - Extra: unknown activation policy falls back to AX safely

    func test_unknownActivationPolicy_fallsBackToAX() {
        // .prohibited is an ActivationPolicy value the outer eligibility
        // filter excludes, but if it ever reaches the classifier we
        // must not silently drop it.
        let facts = Facts(pid: 999, bundleID: "com.weird.app", policy: .prohibited)
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: [facts],
            cgSnapshot: .success(pidsWithAnyWindow: []),
            bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [.some(999)])
    }

    // MARK: - Extra: empty input yields empty output

    func test_emptyAppList_producesEmptyClassification() {
        let result = CascadeOrchestrator.classifyEligibleApps(
            apps: [], cgSnapshot: .success(pidsWithAnyWindow: []), bypassSet: []
        )
        XCTAssertEqual(result.pidsForAXCall, [])
        XCTAssertEqual(result.axEnumeratedCount, 0)
        XCTAssertEqual(result.regularCount, 0)
        XCTAssertEqual(result.accessoryCount, 0)
    }
}
