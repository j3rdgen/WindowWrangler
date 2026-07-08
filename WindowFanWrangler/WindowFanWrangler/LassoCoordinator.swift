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

    /// State of the current mouse drag while lasso mode is on.
    /// Populated on mouseDown, mutated on mouseDragged, cleared on
    /// mouseUp / Escape / stop.
    private var currentDrag: DragState?

    /// Kind of drag currently in progress and its bookkeeping.
    private enum DragState {
        /// Existing rubber-band lasso — creates/replaces the selection
        /// as the mouse moves.
        case rubberBand(anchor: CGPoint)
        /// M6 group drag — the mouse-down hit a currently-selected
        /// window. `primaryWindowID` is the window the user actually
        /// grabbed; its read-back position paces the overlay so the
        /// outlines track the ACTUAL windows (which may lag the cursor
        /// due to target-app AX latency) instead of racing ahead to the
        /// target position.
        case groupDrag(
            anchor: CGPoint,
            primaryWindowID: CGWindowID,
            snapshots: [GroupDragSnapshot]
        )
    }

    /// Per-window state captured at group-drag start. AX element is
    /// resolved eagerly here so the per-frame drag update can call
    /// `WindowMutator.setPosition` directly without re-enumerating
    /// each app's window list every mouse move.
    private struct GroupDragSnapshot {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let originalFrame: CGRect
        let axElement: AXUIElement
    }

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
        overlay.endGroupDrag()
        overlay.hideIfEmpty()
        modeHint.hide()
        currentDrag = nil
        if isLassoModeActive {
            isLassoModeActive = false
            onLassoModeChanged?(false)
        }
    }

    // MARK: - Wiring

    private func wireEvents() {
        eventMonitor.onLassoDragBegan = { [weak self] point in
            guard let self else { return }
            // Hit-test: is the mouse-down over a currently-selected
            // window? If yes → M6 group drag; if no → existing
            // rubber-band lasso.
            let vis = self.visibleSelectionWindows()
            if let hit = vis.reversed().first(where: { $0.frame.contains(point) }) {
                let snapshots = self.resolveSnapshots(from: vis)
                self.currentDrag = .groupDrag(
                    anchor: point,
                    primaryWindowID: hit.windowID,
                    snapshots: snapshots
                )
                // Snapshot the panel + view state now so `updateGroupDrag`
                // can pan the panel via `setFrameOrigin` on every mouse
                // event instead of going through the full redraw path.
                // The panel already exists because a selection was drawn
                // before the drag started.
                self.overlay.beginGroupDrag()
                Log.lasso.info(
                    "Group drag began on window \(hit.windowID, privacy: .public) ('\(hit.ownerName, privacy: .public)') — \(snapshots.count, privacy: .public) window(s) will move"
                )
            } else {
                self.currentDrag = .rubberBand(anchor: point)
                let rect = CGRect(origin: point, size: .zero)
                self.overlay.showLassoRect(rect)
                self.updateSelection(forLassoRect: rect)
                Log.lasso.info(
                    "Rubber-band began at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)"
                )
            }
        }

        eventMonitor.onLassoDragUpdated = { [weak self] point in
            guard let self, let drag = self.currentDrag else { return }
            switch drag {
            case .rubberBand(let anchor):
                let rect = Self.rectBetween(anchor, point)
                self.overlay.showLassoRect(rect)
                self.updateSelection(forLassoRect: rect)
            case .groupDrag(let anchor, let primaryID, let snapshots):
                // Read the primary window's actual position BEFORE
                // issuing this event's write. The read reflects the
                // effect of the PREVIOUS event's write, which had a
                // full inter-event interval to propagate through the
                // target app's runloop and reach WindowServer. That's
                // as close to "where the pixels actually are right
                // now" as we can get without a display link.
                //
                // Pacing the overlay by this read keeps the outlines
                // pinned to the real windows even when target apps
                // (Chrome, Zoom) are slow to process AX writes. The
                // outlines and windows may both trail the cursor
                // slightly on a fast drag — that's inherent to AX —
                // but they trail together, so the outlines stay
                // attached.
                let paceOffset: CGPoint
                if let primary = snapshots.first(where: { $0.windowID == primaryID }),
                   let actualAX = AXWindowEnumerator.currentFrame(of: primary.axElement) {
                    let actual = CoordinateSpace.cocoaRect(fromAX: actualAX)
                    paceOffset = CGPoint(
                        x: actual.origin.x - primary.originalFrame.origin.x,
                        y: actual.origin.y - primary.originalFrame.origin.y
                    )
                } else {
                    paceOffset = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                }
                self.overlay.updateGroupDrag(offset: paceOffset)

                // Now issue this event's write — LIVE movement of the
                // real windows to the cursor's current target. Next
                // event's read will reflect where these writes land.
                let targetDelta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                for snap in snapshots {
                    let newFrame = snap.originalFrame.offsetBy(
                        dx: targetDelta.x, dy: targetDelta.y
                    )
                    WindowMutator.setPosition(of: snap.axElement, cocoaFrame: newFrame)
                }
            }
        }

        eventMonitor.onLassoDragEnded = { [weak self] point in
            guard let self, let drag = self.currentDrag else { return }
            switch drag {
            case .rubberBand(let anchor):
                let rect = Self.rectBetween(anchor, point)
                if rect.isEmpty {
                    // Click without any drag — treat as a single click.
                    // On a window: replace selection with just that
                    // window. On empty space: clear selection.
                    self.applyClick(at: anchor)
                } else {
                    self.updateSelection(forLassoRect: rect)
                }
                self.overlay.hideLassoRect()
                Log.lasso.info(
                    "Rubber-band ended; selection has \(self.selection.count, privacy: .public) window(s)"
                )
            case .groupDrag(let anchor, _, let snapshots):
                let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                // Exit the fast-path pan mode before refreshing frames —
                // the next `setSelectionFrames` call needs to go through
                // the normal redraw path so the panel resizes to the
                // (possibly new) union bounds.
                self.overlay.endGroupDrag()
                if delta == .zero {
                    // Click without any drag on a selected window —
                    // per the same rule, replace selection with just
                    // that window. Real windows never moved.
                    self.applyClick(at: anchor)
                    self.overlay.setSelectionFrames(self.visibleSelectionFrames())
                } else {
                    // Windows already moved live during onDragUpdated
                    // via setPosition. Nothing further to write here;
                    // just refresh the overlay from the system's fresh
                    // frames so a subsequent redraw (e.g. Space change)
                    // finds the up-to-date positions.
                    self.overlay.setSelectionFrames(self.visibleSelectionFrames())
                }
                Log.lasso.info(
                    "Group drag ended; moved \(snapshots.count, privacy: .public) window(s) by (\(Int(delta.x), privacy: .public),\(Int(delta.y), privacy: .public))"
                )
            }
            self.currentDrag = nil
        }

        eventMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            let wasActive = self.isLassoModeActive
            let wasDragging = self.currentDrag != nil
            if !self.selection.isEmpty || wasDragging || wasActive {
                Log.lasso.notice("Escape pressed — exiting lasso, clearing selection")
                self.selection.clear()
                self.currentDrag = nil
                self.overlay.hideLassoRect()
                // If we were in a group-drag fast path, exit it so the
                // overlay hides via the normal `updateWindow` flow (a
                // stale groupDragBase would prevent the empty-frames
                // teardown from taking effect).
                self.overlay.endGroupDrag()
                // Group drag is now LIVE: real windows have already been
                // moved to their current position via each setPosition
                // call, so canceling just stops the drag where it is —
                // matches the user's "stops where the cancellation
                // initiated" spec. No positions to restore.
                //
                // Cancel the eventMonitor's in-flight drag so the next
                // mouseUp doesn't get silently consumed (it would fire
                // onLassoDragEnded with nil state and the event would
                // still be eaten by the tap, swallowing the user's
                // mouse release with nothing visible to show for it).
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

    /// The currently-selected windows that are visible on the active
    /// Space, with FRESH frames from the system's on-screen window
    /// list. Filters by `windowID` against `optionOnScreenOnly` — this
    /// is what keeps stale selection outlines from lingering on Spaces
    /// where the underlying windows don't exist. Also refreshes frames
    /// so hit-testing on mouse-down uses each window's actual current
    /// position, not the (possibly stale) frame stored at selection
    /// time. Selection state itself is unchanged.
    private func visibleSelectionWindows() -> [VisibleWindow] {
        let visible = CrossAppWindowEnumerator.allVisibleWindows()
        let selectedIDs = Set(selection.ordered.map(\.windowID))
        return visible.filter { selectedIDs.contains($0.windowID) }
    }

    private func visibleSelectionFrames() -> [CGRect] {
        visibleSelectionWindows().map(\.frame)
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

    /// Returns the currently-selected window at `point`, or nil if the
    /// point is on empty space, on an unselected window, or on the
    /// desktop. Used on mouse-down in lasso mode to decide whether the
    /// gesture is a rubber-band selection (start rect from that point)
    /// or a group drag (move the whole selection).
    private func selectedWindowAt(_ point: CGPoint) -> VisibleWindow? {
        // Iterate reversed so windows enumerated LATER (typically
        // closer to the front in `allVisibleWindows`) win ties for
        // overlapping selection frames — reasonable heuristic without
        // a real z-order query.
        return visibleSelectionWindows().reversed().first { $0.frame.contains(point) }
    }

    /// Returns the top-most visible window (selected or not) at
    /// `point`, or nil for empty space. Used to implement "click on
    /// any window replaces the selection with just that window."
    private func topmostWindowAt(_ point: CGPoint) -> VisibleWindow? {
        // Same z-order heuristic as `selectedWindowAt` — later in the
        // enumeration wins for overlapping frames.
        return CrossAppWindowEnumerator.allVisibleWindows()
            .reversed()
            .first { $0.frame.contains(point) }
    }

    /// Handles a click (mouse-down + immediate mouse-up, no drag) at
    /// `point`. Per the lasso-mode click contract: clicking on any
    /// window replaces the entire selection with just that window;
    /// clicking on empty space clears the selection.
    private func applyClick(at point: CGPoint) {
        if let clicked = topmostWindowAt(point) {
            selection.replace(with: [clicked])
        } else {
            selection.clear()
        }
    }

    // MARK: - M6 group drag

    /// Resolves AX elements for every visible-selected window ONCE at
    /// drag start. `VisibleWindow` (from `CGWindowListCopyWindowInfo`)
    /// doesn't carry an `AXUIElement` — CGWindowID has no public
    /// mapping to AX. So we enumerate each owning app's window list
    /// once and match by frame. Any window that can't be resolved is
    /// silently dropped from the drag; the rest still move together.
    ///
    /// The whole point of caching axElements in the snapshot is so the
    /// per-frame `setPosition` call in `onLassoDragUpdated` doesn't
    /// need to re-enumerate — that would blow the CGEventTap's
    /// ~75ms-per-callback budget with 5+ selected windows.
    private func resolveSnapshots(from visible: [VisibleWindow]) -> [GroupDragSnapshot] {
        let byPID = Dictionary(grouping: visible, by: \.ownerPID)
        var snapshots: [GroupDragSnapshot] = []
        snapshots.reserveCapacity(visible.count)
        for (pid, windows) in byPID {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let axWindows = AXWindowEnumerator.windows(of: app)
            for win in windows {
                guard let match = axWindows.first(where: {
                    Self.framesApproximatelyEqual($0.frame, win.frame, tolerance: 4)
                }) else { continue }
                snapshots.append(GroupDragSnapshot(
                    windowID: win.windowID,
                    ownerPID: win.ownerPID,
                    originalFrame: win.frame,
                    axElement: match.axElement
                ))
            }
        }
        return snapshots
    }

    private static func framesApproximatelyEqual(
        _ a: CGRect,
        _ b: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(a.minX - b.minX) <= tolerance &&
        abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance &&
        abs(a.height - b.height) <= tolerance
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
