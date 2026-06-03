//
//  CoordinateSpaceTests.swift
//  Window WranglerTests
//
//  Verifies the AX ↔ Cocoa coordinate conversion is a strict inverse
//  pair (round-trip preserves rectangles) and that the conversion uses
//  the primary display as the y-flip pivot (which is how macOS itself
//  defines the global coordinate space).
//
//  No mocking of NSScreen needed — the conversion uses
//  `NSScreen.screens.first` which is always present on a real Mac. We
//  derive expected values from whatever the primary display is at test
//  time.
//

import XCTest
import AppKit
@testable import Window_Wrangler

final class CoordinateSpaceTests: XCTestCase {

    func test_axToCocoa_isInverseOfCocoaToAx() {
        let inputs: [CGRect] = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 250, y: 150, width: 800, height: 600),
            CGRect(x: -200, y: -100, width: 400, height: 300),  // off-primary-screen-on-left
        ]
        for input in inputs {
            let ax = CoordinateSpace.axRect(fromCocoa: input)
            let roundtrip = CoordinateSpace.cocoaRect(fromAX: ax)
            XCTAssertEqual(roundtrip.origin.x, input.origin.x, accuracy: 0.001)
            XCTAssertEqual(roundtrip.origin.y, input.origin.y, accuracy: 0.001)
            XCTAssertEqual(roundtrip.size.width, input.size.width, accuracy: 0.001)
            XCTAssertEqual(roundtrip.size.height, input.size.height, accuracy: 0.001)
        }
    }

    func test_cocoaToAx_pivotsAtPrimaryDisplayTop() {
        // A Cocoa rect with bottom-left at (0,0) of the primary display
        // should land in AX at top-left (0, primary.height - height).
        guard let primary = NSScreen.screens.first else {
            XCTFail("test environment has no screens"); return
        }
        let cocoaBottomLeftOfPrimary = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ax = CoordinateSpace.axRect(fromCocoa: cocoaBottomLeftOfPrimary)
        XCTAssertEqual(ax.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(ax.origin.y, primary.frame.height - 100, accuracy: 0.001)
        XCTAssertEqual(ax.size, cocoaBottomLeftOfPrimary.size)
    }

    func test_axOriginIsAtPrimaryTopLeft() {
        // A degenerate-height "rect" placed at AX origin should map to
        // the very top edge of the primary display in Cocoa coords.
        guard let primary = NSScreen.screens.first else {
            XCTFail("test environment has no screens"); return
        }
        let axTopLeft = CGRect(x: 0, y: 0, width: 100, height: 0)
        let cocoa = CoordinateSpace.cocoaRect(fromAX: axTopLeft)
        XCTAssertEqual(cocoa.minY + cocoa.height, primary.frame.height, accuracy: 0.001)
    }

    func test_size_isPreservedUnderConversion() {
        // Conversion only flips Y; width/height never change.
        let rects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 100, y: 200, width: 1280, height: 720),
            CGRect(x: -500, y: 800, width: 2560, height: 1440),
        ]
        for r in rects {
            XCTAssertEqual(CoordinateSpace.axRect(fromCocoa: r).size, r.size)
            XCTAssertEqual(CoordinateSpace.cocoaRect(fromAX: r).size, r.size)
        }
    }

    func test_screenFrameContaining_returnsScreenWhenPointInside() {
        guard let primary = NSScreen.screens.first else {
            XCTFail("test environment has no screens"); return
        }
        // Cocoa coords: center of primary is inside the primary's frame.
        let center = CGPoint(x: primary.frame.midX, y: primary.frame.midY)
        let result = CoordinateSpace.screenFrame(containing: center)
        XCTAssertTrue(result.contains(center))
    }

    func test_screenFrameContaining_returnsPrimary_forUncontainedPoint() {
        guard let primary = NSScreen.screens.first else {
            XCTFail("test environment has no screens"); return
        }
        // A point well off every conceivable display falls back to primary.
        let farAway = CGPoint(x: -1_000_000, y: -1_000_000)
        XCTAssertEqual(CoordinateSpace.screenFrame(containing: farAway), primary.frame)
    }
}
