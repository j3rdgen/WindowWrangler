//
//  FanGeometryTests.swift
//  Window WranglerTests
//
//  Unit tests for the pure cascade math in `FanGeometry.computeCascade`.
//  Validates:
//   - degenerate inputs (empty, single window)
//   - direction sign (downLeft vs downRight)
//   - uniform target sizing
//   - off-screen constraint: rigid shift when bounding box fits
//   - reveal-reduction when natural cascade exceeds screen
//   - anchor position preservation
//
//  No AppKit or AX dependency — `FanGeometry` is a pure function over
//  CGRect/CGPoint/CGSize values, so these tests run instantly with no
//  external setup.
//

import XCTest
@testable import Window_Wrangler

final class FanGeometryTests: XCTestCase {

    // MARK: - Degenerate inputs

    func test_emptyInput_returnsEmpty() {
        let result = FanGeometry.computeCascade(
            windows: [],
            screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
            targetSize: CGSize(width: 500, height: 400),
            direction: .downRight
        )
        XCTAssertEqual(result, [])
    }

    func test_singleWindow_resizesAtCurrentOrigin() {
        let win = CGRect(x: 100, y: 200, width: 300, height: 250)
        let result = FanGeometry.computeCascade(
            windows: [win],
            screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
            targetSize: CGSize(width: 500, height: 400),
            direction: .downRight
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].origin, win.origin)
        XCTAssertEqual(result[0].size, CGSize(width: 500, height: 400))
    }

    // MARK: - Uniform target sizing

    func test_allWindowsResizedToTarget() {
        // Build the input windows in stages — packing all the CGFloat
        // conversions into the CGRect initializer in one expression
        // blew Swift's type-inference budget and prevented the test
        // file from compiling.
        let windows: [CGRect] = (0..<5).map { i in
            let x = CGFloat(i * 50)
            let y = CGFloat(i * 30)
            let w = CGFloat(100 + i * 10)
            let h = CGFloat(80 + i * 5)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let target = CGSize(width: 600, height: 400)
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 2000, height: 1500),
            targetSize: target,
            direction: .downRight
        )
        for rect in result {
            XCTAssertEqual(rect.size, target, "every cascaded window should match targetSize")
        }
    }

    // MARK: - Direction sign

    func test_downLeft_lateralOffsetPositive() {
        let windows = [
            CGRect(x: 500, y: 500, width: 400, height: 300),
            CGRect(x: 510, y: 510, width: 400, height: 300),
            CGRect(x: 520, y: 520, width: 400, height: 300),
        ]
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 3000, height: 2000),
            targetSize: CGSize(width: 400, height: 300),
            direction: .downLeft
        )
        // downLeft: each successive window offsets +x relative to the anchor
        XCTAssertGreaterThan(result[1].minX, result[0].minX)
        XCTAssertGreaterThan(result[2].minX, result[1].minX)
    }

    func test_downRight_lateralOffsetNegative() {
        let windows = [
            CGRect(x: 1500, y: 500, width: 400, height: 300),
            CGRect(x: 1510, y: 510, width: 400, height: 300),
            CGRect(x: 1520, y: 520, width: 400, height: 300),
        ]
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 3000, height: 2000),
            targetSize: CGSize(width: 400, height: 300),
            direction: .downRight
        )
        // downRight: each successive window offsets -x relative to the anchor
        XCTAssertLessThan(result[1].minX, result[0].minX)
        XCTAssertLessThan(result[2].minX, result[1].minX)
    }

    func test_bothDirections_verticalOffsetIsUpwardInCocoa() {
        // Cocoa y-up: subsequent windows have HIGHER y (above the anchor).
        let windows = (0..<3).map { _ in CGRect(x: 500, y: 500, width: 400, height: 300) }
        for direction in [CascadeDirection.downLeft, .downRight] {
            let result = FanGeometry.computeCascade(
                windows: windows,
                screen: CGRect(x: 0, y: 0, width: 3000, height: 2000),
                targetSize: CGSize(width: 400, height: 300),
                direction: direction
            )
            XCTAssertGreaterThan(result[1].minY, result[0].minY, "direction \(direction)")
            XCTAssertGreaterThan(result[2].minY, result[1].minY, "direction \(direction)")
        }
    }

    // MARK: - Off-screen constraint

    func test_naturalCascadeOffRight_rigidShifts_doesNotReduceReveals() {
        // Anchor near right edge → natural cascade would push first window
        // off the right (downLeft = +x sign). Bounding box still fits in
        // screen, so we expect a rigid leftward shift, not reveal reduction.
        let windows = [
            CGRect(x: 1800, y: 100, width: 400, height: 300),
            CGRect(x: 1810, y: 110, width: 400, height: 300),
            CGRect(x: 1820, y: 120, width: 400, height: 300),
        ]
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 2000, height: 1500),
            targetSize: CGSize(width: 400, height: 300),
            direction: .downLeft
        )
        // Last window should fit within the screen's right edge.
        XCTAssertLessThanOrEqual(result.last!.maxX, 2000.001)

        // Spacing between successive windows should still be at the natural
        // 60pt lateral / 28pt header — no reduction since the box fits.
        XCTAssertEqual(result[1].minX - result[0].minX, 60, accuracy: 0.5)
        XCTAssertEqual(result[1].minY - result[0].minY, 28, accuracy: 0.5)
    }

    func test_manyWindows_naturalCascadeDoesNotFit_revealsReduce() {
        // 20 windows × 60pt lateral = 1140pt of lateral spread, plus 400pt
        // window width = 1540pt total. Screen is 1000pt wide → must reduce.
        let windows: [CGRect] = (0..<20).map { _ in
            CGRect(x: 100, y: 100, width: 400, height: 300)
        }
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
            targetSize: CGSize(width: 400, height: 300),
            direction: .downLeft
        )
        XCTAssertEqual(result.count, 20)
        // All windows must fit within the screen bounds.
        for rect in result {
            XCTAssertGreaterThanOrEqual(rect.minX, -0.001)
            XCTAssertLessThanOrEqual(rect.maxX, 1000.001)
            XCTAssertGreaterThanOrEqual(rect.minY, -0.001)
            XCTAssertLessThanOrEqual(rect.maxY, 800.001)
        }
        // Spacing should be < 60pt (reduced from natural).
        let actualLateral = result[1].minX - result[0].minX
        XCTAssertLessThan(actualLateral, 60)
        XCTAssertGreaterThanOrEqual(actualLateral, 0)
    }

    // MARK: - Anchor position preservation

    func test_anchorIndexZero_seedsCascadeOrigin_whenFits() {
        // When natural cascade fits, windows[0]'s origin should remain
        // unchanged after shiftToFit (since shift is zero).
        let anchor = CGRect(x: 200, y: 300, width: 400, height: 300)
        let windows = [
            anchor,
            CGRect(x: 220, y: 320, width: 400, height: 300),
            CGRect(x: 240, y: 340, width: 400, height: 300),
        ]
        let result = FanGeometry.computeCascade(
            windows: windows,
            screen: CGRect(x: 0, y: 0, width: 2000, height: 1500),
            targetSize: CGSize(width: 400, height: 300),
            direction: .downLeft
        )
        XCTAssertEqual(result[0].origin, anchor.origin)
    }
}
