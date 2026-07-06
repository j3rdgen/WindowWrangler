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

    /// Retained observer token for the Space-change notification, so
    /// `deinit` can remove it. Selection highlights are Space-scoped —
    /// we redraw whenever the active Space changes so stale outlines
    /// don't linger on a Space where the underlying windows don't live.
    private var activeSpaceObserver: NSObjectProtocol?

    init(selection: WindowSelection) {
        self.selection = selection
        wireEvents()
    }

    deinit {
        if let token = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
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
        overlay.setSelectionFrames(visibleSelectionFrames())
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
        // future paths add to/remove from it), redraw the overlay
        // filtered to windows currently visible on the active Space.
        selection.onChange = { [weak self] in
            guard let self else { return }
            self.overlay.setSelectionFrames(self.visibleSelectionFrames())
            self.overlay.hideIfEmpty()
        }

        // Redraw when the active Space changes. Selection state is
        // preserved; we just re-filter what the overlay draws. When
        // the user swipes to a Space that contains none of the
        // selected windows, the overlay hides itself (empty frames);
        // when they swipe back, it reappears.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Destroy the old overlay panel (it's pinned to the
                // previous Space and already animated off). The next
                // frame-setting call recreates a fresh panel on the
                // now-active Space.
                self.overlay.spaceDidChange()
                self.overlay.setSelectionFrames(self.visibleSelectionFrames())
                self.overlay.hideIfEmpty()
            }
        }
    }

    /// Frames of the currently-selected windows that are actually
    /// visible on the active Space (per each display, when displays
    /// have separate Spaces). Filters by `windowID` against the
    /// system's `optionOnScreenOnly` window list — this is what keeps
    /// stale selection outlines from lingering on Spaces where the
    /// underlying windows don't exist. Selection state itself is
    /// unchanged; when the user swipes back to a Space that contains
    /// the selected windows, this returns their frames again and the
    /// overlay reappears.
    private func visibleSelectionFrames() -> [CGRect] {
        let visibleIDs = Set(CrossAppWindowEnumerator.allVisibleWindows().map(\.windowID))
        return selection.ordered
            .filter { visibleIDs.contains($0.windowID) }
            .map(\.frame)
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
