//
//  WindowSelectionTests.swift
//  Window WranglerTests
//
//  Validates the state-holder semantics of `WindowSelection`:
//   - replace / clear update both `count` and `frames`
//   - `frames` and `ordered` are deterministic (sorted by windowID)
//   - `onChange` fires on change, NOT on no-op
//   - duplicate-window-ID input collapses to one entry
//   - the no-change short-circuit doesn't fire spurious onChange calls
//
//  No async or UI surface needed — `WindowSelection` is pure state.
//

import XCTest
import CoreGraphics
@testable import Window_Wrangler

@MainActor
final class WindowSelectionTests: XCTestCase {

    private func makeWindow(id: CGWindowID, frame: CGRect = .zero, owner: String = "Test") -> VisibleWindow {
        VisibleWindow(windowID: id, ownerPID: 0, ownerName: owner, frame: frame)
    }

    // MARK: - Basic state

    func test_initiallyEmpty() {
        let sel = WindowSelection()
        XCTAssertTrue(sel.isEmpty)
        XCTAssertEqual(sel.count, 0)
        XCTAssertEqual(sel.frames, [])
    }

    func test_replace_setsWindows_andCount() {
        let sel = WindowSelection()
        let wins = [
            makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            makeWindow(id: 2, frame: CGRect(x: 100, y: 100, width: 10, height: 10)),
        ]
        sel.replace(with: wins)
        XCTAssertEqual(sel.count, 2)
        XCTAssertFalse(sel.isEmpty)
        XCTAssertTrue(sel.contains(1))
        XCTAssertTrue(sel.contains(2))
    }

    func test_clear_resetsState() {
        let sel = WindowSelection()
        sel.replace(with: [makeWindow(id: 1), makeWindow(id: 2)])
        sel.clear()
        XCTAssertTrue(sel.isEmpty)
        XCTAssertEqual(sel.count, 0)
    }

    // MARK: - Deterministic ordering

    func test_frames_orderedByWindowID() {
        let sel = WindowSelection()
        let wins = [
            makeWindow(id: 30, frame: CGRect(x: 30, y: 0, width: 1, height: 1)),
            makeWindow(id: 10, frame: CGRect(x: 10, y: 0, width: 1, height: 1)),
            makeWindow(id: 20, frame: CGRect(x: 20, y: 0, width: 1, height: 1)),
        ]
        sel.replace(with: wins)
        // Sorted ascending: id 10 → 20 → 30 → minX 10, 20, 30
        let xs = sel.frames.map { Int($0.minX) }
        XCTAssertEqual(xs, [10, 20, 30])
    }

    func test_ordered_orderedByWindowID() {
        let sel = WindowSelection()
        sel.replace(with: [
            makeWindow(id: 99),
            makeWindow(id: 1),
            makeWindow(id: 50),
        ])
        XCTAssertEqual(sel.ordered.map(\.windowID), [1, 50, 99])
    }

    // MARK: - onChange semantics

    func test_replace_firesOnChange_whenContentChanges() {
        let sel = WindowSelection()
        var fires = 0
        sel.onChange = { fires += 1 }
        sel.replace(with: [makeWindow(id: 1)])
        XCTAssertEqual(fires, 1)
        sel.replace(with: [makeWindow(id: 1), makeWindow(id: 2)])
        XCTAssertEqual(fires, 2)
    }

    func test_replace_doesNotFire_whenNoChange() {
        let sel = WindowSelection()
        let wins = [makeWindow(id: 1, frame: CGRect(x: 5, y: 5, width: 10, height: 10))]
        sel.replace(with: wins)
        var fires = 0
        sel.onChange = { fires += 1 }
        sel.replace(with: wins)  // identical
        XCTAssertEqual(fires, 0, "no-change replace should NOT fire onChange")
    }

    func test_replace_fires_whenFrameChangesButKeysSame() {
        let sel = WindowSelection()
        sel.replace(with: [makeWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        var fires = 0
        sel.onChange = { fires += 1 }
        // Same windowID, different frame.
        sel.replace(with: [makeWindow(id: 1, frame: CGRect(x: 50, y: 50, width: 10, height: 10))])
        XCTAssertEqual(fires, 1)
    }

    func test_clear_firesOnChange_whenNonEmpty() {
        let sel = WindowSelection()
        sel.replace(with: [makeWindow(id: 1)])
        var fires = 0
        sel.onChange = { fires += 1 }
        sel.clear()
        XCTAssertEqual(fires, 1)
    }

    func test_clear_doesNotFire_whenAlreadyEmpty() {
        let sel = WindowSelection()
        var fires = 0
        sel.onChange = { fires += 1 }
        sel.clear()
        XCTAssertEqual(fires, 0)
    }

    // MARK: - Duplicate ID handling

    func test_replace_duplicateIDs_collapseToLast() {
        let sel = WindowSelection()
        let firstFrame = CGRect(x: 10, y: 0, width: 1, height: 1)
        let secondFrame = CGRect(x: 20, y: 0, width: 1, height: 1)
        sel.replace(with: [
            makeWindow(id: 1, frame: firstFrame),
            makeWindow(id: 1, frame: secondFrame),
        ])
        // Implementation uses `Dictionary(_:uniquingKeysWith:)` which
        // keeps the LAST observed value for a duplicate key — chosen
        // over `uniqueKeysWithValues` (which would trap) so a glitchy
        // CGWindowList result can't crash the app.
        XCTAssertEqual(sel.count, 1)
        XCTAssertEqual(sel.frames.first, secondFrame)
    }
}
