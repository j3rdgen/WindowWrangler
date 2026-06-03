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
    ///
    /// Short-circuits with no `onChange` fire if the new dictionary
    /// holds the same windowIDs with the same frames as the current
    /// one. The earlier implementation compared `Dictionary.values`
    /// directly — that's order-dependent (Swift makes no ordering
    /// guarantee on `.values`) and would sometimes report "changed"
    /// when nothing had. During a lasso drag tick this was firing
    /// the menu rebuild + overlay redraw 60Hz unnecessarily.
    func replace(with list: [VisibleWindow]) {
        // `Dictionary(uniqueKeysWithValues:)` would TRAP on a duplicate
        // windowID. CGWindowList shouldn't return duplicates in practice,
        // but a system glitch could — and a crash on a state-holder
        // update would be a particularly ugly failure mode. Use the
        // uniquing initializer that keeps the LAST observed value for
        // any duplicate key.
        let newDict = Dictionary(
            list.map { ($0.windowID, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        if newDict.keys == windows.keys {
            var anyFrameChanged = false
            for (id, newWin) in newDict where windows[id]?.frame != newWin.frame {
                anyFrameChanged = true
                break
            }
            if !anyFrameChanged { return }
        }
        windows = newDict
        onChange?()
    }

    func clear() {
        guard !windows.isEmpty else { return }
        windows.removeAll()
        onChange?()
    }

    /// All currently-selected window frames in Cocoa coordinates,
    /// ordered deterministically by `windowID` so repeated reads of
    /// the same selection yield the same sequence. This matters for
    /// M6 group drag (cluster preview must render in a stable order)
    /// and avoids spurious visual differences between redraws.
    var frames: [CGRect] {
        windows.keys.sorted().compactMap { windows[$0]?.frame }
    }

    /// All currently-selected windows, ordered deterministically by
    /// `windowID`. Same rationale as `frames`.
    var ordered: [VisibleWindow] {
        windows.keys.sorted().compactMap { windows[$0] }
    }
}
