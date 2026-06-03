//
//  LassoCoordinator.swift
//  Window Wrangler
//
//  Wires the M5 modules together: GlobalEventMonitor (input),
//  CrossAppWindowEnumerator (window list), WindowSelection (state),
//  SelectionOverlay (rendering).
//
//  Per CLAUDE.md: orchestrators read/write through dedicated modules
//  rather than holding direct references. This class IS the
//  orchestrator for the lasso flow.
//

import AppKit
import os

@MainActor
final class LassoCoordinator {

    private let eventMonitor = GlobalEventMonitor()
    private let overlay = SelectionOverlay()
    private let modeHint = LassoModeHint()
    let selection: WindowSelection

    /// Origin point of the current drag, set on mouseDown.
    private var dragAnchor: CGPoint?

    /// True when the user has toggled lasso mode on via the global
    /// shortcut. Plain click-and-drag now produces a lasso; otherwise
    /// mouse events are ignored.
    private(set) var isLassoModeActive: Bool = false

    /// Fires whenever lasso mode is toggled. Caller (AppDelegate) uses
    /// this to refresh the menu's "Lasso mode: ON/OFF" indicator.
    var onLassoModeChanged: ((Bool) -> Void)?

    init(selection: WindowSelection) {
        self.selection = selection
        wireEvents()
    }

    /// Toggles lasso mode on/off — bound to the ⌃⌥⌘C global shortcut.
    func toggleLassoMode() {
        isLassoModeActive.toggle()
        eventMonitor.isLassoModeActive = isLassoModeActive
        if isLassoModeActive {
            modeHint.show()
        } else {
            modeHint.hide()
        }
        Log.lasso.notice("Lasso mode: \(self.isLassoModeActive ? "ON" : "OFF", privacy: .public)")
        onLassoModeChanged?(isLassoModeActive)
    }

    /// Starts observing global events. Should be called only after
    /// Accessibility permission is granted (NSEvent's global keyDown
    /// monitor requires it). Idempotent.
    func start() {
        eventMonitor.start()
        // Render any pre-existing selection (e.g., on permission re-grant).
        overlay.setSelectionFrames(selection.frames)
    }

    /// Stops the global monitors. Call when permission is revoked.
    ///
    /// Resets `isLassoModeActive` to false AND notifies subscribers, so
    /// the menu doesn't keep showing "Lasso Mode: ON" after the lasso
    /// has actually been torn down. Without this notification the menu
    /// state can drift from the truth.
    func stop() {
        eventMonitor.stop()
        overlay.hideLassoRect()
        overlay.setSelectionFrames([])
        overlay.hideIfEmpty()
        modeHint.hide()
        dragAnchor = nil
        if isLassoModeActive {
            isLassoModeActive = false
            onLassoModeChanged?(false)
        }
    }

    // MARK: - Wiring

    private func wireEvents() {
        eventMonitor.onLassoDragBegan = { [weak self] point in
            guard let self else { return }
            self.dragAnchor = point
            let rect = CGRect(origin: point, size: .zero)
            self.overlay.showLassoRect(rect)
            self.updateSelection(forLassoRect: rect)
            Log.lasso.info("Drag began at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)")
        }

        eventMonitor.onLassoDragUpdated = { [weak self] point in
            guard let self, let anchor = self.dragAnchor else { return }
            let rect = Self.rectBetween(anchor, point)
            self.overlay.showLassoRect(rect)
            self.updateSelection(forLassoRect: rect)
        }

        eventMonitor.onLassoDragEnded = { [weak self] point in
            guard let self, let anchor = self.dragAnchor else { return }
            let rect = Self.rectBetween(anchor, point)
            self.updateSelection(forLassoRect: rect)
            self.overlay.hideLassoRect()
            self.dragAnchor = nil
            Log.lasso.info("Drag ended; selection has \(self.selection.count, privacy: .public) window(s)")
        }

        eventMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            let wasActive = self.isLassoModeActive
            let wasDragging = self.dragAnchor != nil
            if !self.selection.isEmpty || wasDragging || wasActive {
                Log.lasso.notice("Escape pressed — exiting lasso, clearing selection")
                self.selection.clear()
                self.dragAnchor = nil
                self.overlay.hideLassoRect()
                // Cancel the eventMonitor's in-flight drag so the next
                // mouseUp doesn't get silently consumed (it would fire
                // onLassoDragEnded with a nil anchor and the event
                // would still be eaten by the tap, swallowing the
                // user's mouse release with nothing visible to show
                // for it).
                if wasDragging {
                    self.eventMonitor.cancelDrag()
                }
                if wasActive {
                    self.isLassoModeActive = false
                    self.eventMonitor.isLassoModeActive = false
                    self.modeHint.hide()
                    self.onLassoModeChanged?(false)
                }
            }
        }

        // Whenever the selection changes (lasso updates it, or other
        // future paths add to/remove from it), redraw the overlay.
        selection.onChange = { [weak self] in
            guard let self else { return }
            self.overlay.setSelectionFrames(self.selection.frames)
            self.overlay.hideIfEmpty()
        }
    }

    // MARK: - Hit-testing

    /// Updates the selection to be the set of visible windows whose
    /// frames intersect `lassoRect`. Matches Finder's lasso behavior:
    /// partial overlap is enough.
    private func updateSelection(forLassoRect lassoRect: CGRect) {
        let allWindows = CrossAppWindowEnumerator.allVisibleWindows()
        let hits = allWindows.filter { $0.frame.intersects(lassoRect) }
        selection.replace(with: hits)
    }

    // MARK: - Helpers

    /// Returns the normalized rectangle between two points (handles
    /// any drag direction).
    private static func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(a.x - b.x)
        let h = abs(a.y - b.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
