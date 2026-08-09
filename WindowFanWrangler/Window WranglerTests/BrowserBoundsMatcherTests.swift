//
//  BrowserBoundsMatcherTests.swift
//  Window WranglerTests
//
//  Pure-matcher tests for `BrowserScripting.matchBrowserWindow`. No
//  live Chromium process required — the matcher operates on a plain
//  list of (index, boundsAX) candidates, so we synthesize scenarios
//  in memory and assert the classification. Covers the fourteen
//  matcher scenarios from the four-part specification.
//
//  These tests intentionally avoid `runScriptAsync` / any AppleScript
//  path. Integration tests that touch the browser live elsewhere.
//

import XCTest
import CoreGraphics
@testable import Window_Wrangler

final class BrowserBoundsMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func requestAt(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func candidate(_ index: Int, _ rect: CGRect) -> (index: Int, boundsAX: CGRect) {
        (index: index, boundsAX: rect)
    }

    // MARK: - 1. One exact candidate

    func test_oneExactCandidate_confidentMatch() {
        let request = requestAt(100, 100, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, request)]
        )
        XCTAssertEqual(result, .confident(index: 1))
    }

    // MARK: - 2. One candidate within tolerance

    func test_oneCandidateWithinTolerance_confidentMatch() {
        let request = requestAt(100, 100, 800, 600)
        // 4pt origin drift — well within the ~48pt center threshold.
        let near = requestAt(104, 103, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(2, near)]
        )
        XCTAssertEqual(result, .confident(index: 2))
    }

    // MARK: - 3. No candidate

    func test_emptyCandidateList_noMatch() {
        let request = requestAt(100, 100, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: []
        )
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - 4. Candidate beyond tolerance

    func test_candidateBeyondTolerance_noMatch() {
        let request = requestAt(100, 100, 800, 600)
        // Center at (500,400); shift a candidate to (5000,4000) —
        // ~6300pt center distance, orders of magnitude past the
        // 48pt threshold.
        let far = requestAt(5000, 4000, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, far)]
        )
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - 5. Two tied candidates (near-equal distances)

    func test_twoCandidatesTied_ambiguous() {
        let request = requestAt(100, 100, 800, 600)
        // Both within tolerance, both approximately equidistant.
        // Difference in center-distance below `nativeBoundsAmbiguityMargin`.
        let a = requestAt(102, 100, 800, 600) // center offset (2, 0), dist 2
        let b = requestAt(98, 100, 800, 600)  // center offset (-2, 0), dist 2
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, a), candidate(2, b)]
        )
        XCTAssertEqual(result, .ambiguous)
    }

    // MARK: - 6. Two candidates with identical bounds

    func test_twoCandidatesIdenticalBounds_ambiguous() {
        let request = requestAt(100, 100, 800, 600)
        let rect = requestAt(105, 100, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, rect), candidate(2, rect)]
        )
        XCTAssertEqual(result, .ambiguous)
    }

    // MARK: - 7. Several candidates with one clear winner

    func test_severalCandidatesOneClearWinner_confidentMatch() {
        let request = requestAt(100, 100, 800, 600)
        // Winner near-exact; runners-up far enough to be outside
        // the ambiguity margin (differ by > 6pt center-distance).
        let winner = requestAt(101, 100, 800, 600)  // center dist ~1
        let far1 = requestAt(200, 200, 800, 600)    // center dist ~141
        let far2 = requestAt(300, 300, 800, 600)    // center dist ~283
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, far1), candidate(2, winner), candidate(3, far2)]
        )
        XCTAssertEqual(result, .confident(index: 2))
    }

    // MARK: - 8. One-to-one assignment for several moves

    func test_oneToOneAssignmentForSeveralMoves() {
        // Three requests, three distinct windows. Each request gets its
        // own confident match; the matcher is pure so we simulate the
        // one-to-one by running it per request and asserting each is
        // confident with a distinct index.
        let winA = requestAt(100, 100, 800, 600)
        let winB = requestAt(1000, 100, 800, 600)
        let winC = requestAt(100, 800, 800, 600)
        let candidates = [
            candidate(1, winA),
            candidate(2, winB),
            candidate(3, winC),
        ]
        for (expected, request) in zip([1, 2, 3], [winA, winB, winC]) {
            let result = BrowserScripting.matchBrowserWindow(
                requestedAX: request,
                candidates: candidates
            )
            XCTAssertEqual(result, .confident(index: expected))
        }
    }

    // MARK: - 9. Duplicate assignment rejected
    //
    // The matcher itself is stateless — duplicate-assignment prevention
    // is a caller-side concern (see setBrowserWindowBoundsBatch). This
    // test asserts that even if a caller re-runs the matcher against
    // the same list for a request that is best-matched by a window
    // already assigned to another request, the matcher does NOT
    // silently pick a next-best duplicate — it returns confident to
    // the actual best, and the caller must dedupe.

    func test_matcherReturnsBestByDistance_notCallerAssignment() {
        let request = requestAt(100, 100, 800, 600)
        let winA = requestAt(100, 100, 800, 600)   // exact
        let winB = requestAt(120, 100, 800, 600)   // 20pt off
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, winA), candidate(2, winB)]
        )
        // Even if the caller has already used index 1 for another
        // request, the matcher returns 1 here — deduping is the
        // caller's job. Documented behavior.
        XCTAssertEqual(result, .confident(index: 1))
    }

    // MARK: - 10. Negative global coordinates
    //
    // Secondary displays sit at negative X or negative Y in the global
    // coordinate space. The matcher must handle these identically.

    func test_negativeCoordinates_confidentMatch() {
        // Display to the left of the primary — negative X origin.
        let request = requestAt(-1440, 100, 800, 600)
        let near = requestAt(-1436, 102, 800, 600)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, near)]
        )
        XCTAssertEqual(result, .confident(index: 1))
    }

    // MARK: - 11. Vertically offset display coordinates
    //
    // AX uses top-left global origin. A display below the primary has
    // a large positive Y offset. Verify the matcher works there.

    func test_verticalOffsetCoordinates_confidentMatch() {
        let request = requestAt(200, 1200, 1000, 700)
        let near = requestAt(202, 1201, 1000, 700)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(5, near)]
        )
        XCTAssertEqual(result, .confident(index: 5))
    }

    // MARK: - 12. Different browser-window-list ordering
    //
    // Chromium returns windows in z-order. The matcher must be
    // order-independent — a confident match's index depends only on
    // the candidate that best matches the request, not the position
    // in the list.

    func test_orderIndependent_confidentMatch() {
        let request = requestAt(100, 100, 800, 600)
        let winner = requestAt(100, 100, 800, 600)
        let noise = requestAt(500, 500, 800, 600)
        let a = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(9, winner), candidate(3, noise)]
        )
        let b = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(3, noise), candidate(9, winner)]
        )
        XCTAssertEqual(a, .confident(index: 9))
        XCTAssertEqual(b, .confident(index: 9))
    }

    // MARK: - 13. Empty response

    func test_emptyResponse_noMatch() {
        let request = requestAt(100, 100, 800, 600)
        // Same as scenario #3 but included explicitly for the spec's
        // 14-point matrix — this represents an AppleScript that
        // successfully returned zero windows.
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: []
        )
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - 14. Malformed response
    //
    // Parsing malformed responses happens in `parseBoundsOnly` (skips
    // lines that don't have the expected field count). Once the parser
    // has done its job, the matcher sees whatever survived. If nothing
    // parses, matcher sees an empty list → noMatch. This test asserts
    // matcher behavior with a partially-degenerate rect that MIGHT
    // reach it: a zero-size window at the origin.

    func test_zeroSizeCandidate_farFromRequest_noMatch() {
        let request = requestAt(500, 500, 800, 600)
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, degenerate)]
        )
        // Center distance from (0,0) to (900,800) is ~1204, way past
        // threshold — noMatch, not a bogus confident.
        XCTAssertEqual(result, .noMatch)
    }

    // MARK: - Additional: two-close-but-not-tied → confident

    func test_twoCloseButOneClearlyBetter_confidentMatch() {
        let request = requestAt(100, 100, 800, 600)
        // Winner is exact (dist 0); second is within threshold but
        // farther than the ambiguity margin.
        let winner = requestAt(100, 100, 800, 600)                  // dist 0
        let second = requestAt(110, 110, 800, 600)                  // dist ~14
        let result = BrowserScripting.matchBrowserWindow(
            requestedAX: request,
            candidates: [candidate(1, winner), candidate(2, second)]
        )
        XCTAssertEqual(result, .confident(index: 1))
    }

    // MARK: - Additional: supportsNativeWindowBounds capability

    func test_supportsNativeWindowBounds_forChromium() {
        XCTAssertTrue(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.google.Chrome"))
        XCTAssertTrue(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.brave.Browser"))
        XCTAssertTrue(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.microsoft.edgemac"))
    }

    func test_supportsNativeWindowBounds_excludesSafari() {
        // Safari's AX writes are reliable and not subject to Chrome's
        // async revert — intentionally NOT covered by the native
        // transport (documented in supportsNativeWindowBounds).
        XCTAssertFalse(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.apple.Safari"))
    }

    func test_supportsNativeWindowBounds_excludesNonBrowsers() {
        XCTAssertFalse(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.apple.finder"))
        XCTAssertFalse(BrowserScripting.supportsNativeWindowBounds(bundleID: "com.apple.Terminal"))
    }
}
