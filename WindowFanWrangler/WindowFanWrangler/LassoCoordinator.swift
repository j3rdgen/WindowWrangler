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

@MainActor
final class LassoCoordinator {

    private let eventMonitor = GlobalEventMonitor()
    private let overlay = SelectionOverlay()
    let selection: WindowSelection

    /// Origin point of the current drag, set on mouseDown.
    private var dragAnchor: CGPoint?

    init(selection: WindowSelection) {
        self.selection = selection
        wireEvents()
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
    func stop() {
        eventMonitor.stop()
        overlay.hideLassoRect()
        overlay.setSelectionFrames([])
        overlay.hideIfEmpty()
        dragAnchor = nil
    }

    // MARK: - Wiring

    private func wireEvents() {
        eventMonitor.onLassoModeEntered = { [weak self] in
            NSLog("[\(AppInfo.displayName)] Lasso mode: ARMED (Option+W held)")
            // Just bring the overlay window up; rectangle appears only
            // once the user actually begins a drag.
            self?.overlay.ensureWindow()
        }

        eventMonitor.onLassoModeExited = { [weak self] in
            NSLog("[\(AppInfo.displayName)] Lasso mode: released")
            // If no drag was in progress, clear the rubber-band
            // visualization. Existing selection persists.
            if self?.dragAnchor == nil {
                self?.overlay.hideLassoRect()
                self?.overlay.hideIfEmpty()
            }
        }

        eventMonitor.onLassoDragBegan = { [weak self] point in
            guard let self else { return }
            self.dragAnchor = point
            let rect = CGRect(origin: point, size: .zero)
            self.overlay.showLassoRect(rect)
            self.updateSelection(forLassoRect: rect)
            NSLog("[\(AppInfo.displayName)] Lasso drag began at \(Int(point.x)),\(Int(point.y))")
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
            NSLog("[\(AppInfo.displayName)] Lasso drag ended; selection has \(self.selection.count) window(s)")
        }

        eventMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            if !self.selection.isEmpty || self.dragAnchor != nil {
                NSLog("[\(AppInfo.displayName)] Escape pressed — clearing selection")
                self.selection.clear()
                self.dragAnchor = nil
                self.overlay.hideLassoRect()
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
