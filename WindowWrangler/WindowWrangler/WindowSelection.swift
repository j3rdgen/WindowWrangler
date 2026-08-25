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

    /// The most-recently-interacted-with window inside the current
    /// selection. Used by the multi-window resize feature to decide
    /// which window's bottom corners get the resize handles. Updated
    /// via `markInteracted(_:)` on mouse-down against a selected
    /// window (regardless of whether it's a click or a drag).
    ///
    /// Returns nil when no interaction has ever happened OR when the
    /// referenced window is no longer in the selection. The caller
    /// is responsible for its own fallback (typically: visually
    /// topmost visible selected window — a z-order fallback the
    /// coordinator can do because it has `CGWindowList` access;
    /// this class deliberately doesn't reach for it).
    ///
    /// Cleared when the referenced window leaves the selection.
    var lastInteractedWindowID: CGWindowID? {
        guard let id = _lastInteractedWindowID, windows[id] != nil else {
            return nil
        }
        return id
    }
    private var _lastInteractedWindowID: CGWindowID?

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
        _lastInteractedWindowID = nil
        onChange?()
    }

    /// Records `id` as the most-recently-interacted window. No-op if
    /// `id` isn't currently in the selection. Fires `onChange` only
    /// if this actually shifted the resolved value — the overlay's
    /// resize-handle position depends on it, so any real change needs
    /// a redraw.
    func markInteracted(_ id: CGWindowID) {
        guard windows[id] != nil else { return }
        let previous = lastInteractedWindowID
        _lastInteractedWindowID = id
        if previous != lastInteractedWindowID {
            onChange?()
        }
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
