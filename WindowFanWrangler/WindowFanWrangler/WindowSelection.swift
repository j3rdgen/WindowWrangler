//
//  WindowSelection.swift
//  Window Wrangler
//
//  State holder for the cross-app window selection produced by the
//  lasso flow. Per CLAUDE.md "Selection state separate": this is
//  the single source of truth; nothing else holds direct window
//  references long-term.
//
//  Pure state — no AX calls, no UI. Other components subscribe via
//  `onChange` and read the current set.
//

import Foundation
import CoreGraphics

@MainActor
final class WindowSelection {

    /// Current selection, keyed by CGWindowID for stable lookup.
    private(set) var windows: [CGWindowID: VisibleWindow] = [:]

    /// Fires whenever the selection changes (add, remove, clear, replace).
    /// Subscribers should be lightweight — the overlay's redraw, the
    /// menu's rebuild.
    var onChange: (() -> Void)?

    var count: Int { windows.count }
    var isEmpty: Bool { windows.isEmpty }

    func contains(_ id: CGWindowID) -> Bool {
        windows[id] != nil
    }

    /// Replaces the entire selection with the given list. Useful when
    /// a lasso drag is updating the selection in bulk on each frame.
    func replace(with list: [VisibleWindow]) {
        let newDict = Dictionary(uniqueKeysWithValues: list.map { ($0.windowID, $0) })
        guard newDict.keys != windows.keys || newDict.values.map(\.frame) != windows.values.map(\.frame) else {
            return  // no actual change
        }
        windows = newDict
        onChange?()
    }

    func clear() {
        guard !windows.isEmpty else { return }
        windows.removeAll()
        onChange?()
    }

    /// All currently-selected window frames in Cocoa coordinates.
    /// Used by the overlay to draw highlight borders.
    var frames: [CGRect] {
        windows.values.map(\.frame)
    }
}
