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
import ApplicationServices
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

    /// Fires after a multi-window resize completes and the windows
    /// have settled. Callback receives the AX elements + fresh frames
    /// of the resized windows (frontmost first) AND the user's INTENDED
    /// drag-target size — the size the user actually released the
    /// corner at, before any per-app clamping. The cascade uses that
    /// as its slot width so a stuck frontmost (System Settings won't
    /// go below 723pt, Chrome clamps up to 1000pt) doesn't inflate
    /// the whole fan to accommodate itself.
    ///
    /// WindowWranglerApp wires this to CascadeOrchestrator with
    /// preserveWindowSizes=true so the re-cascade only repositions
    /// and doesn't try to re-force sizes the apps have already refused.
    var onResizeCompleted: (([EnumeratedWindow], CGSize) -> Void)?

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
        /// Multi-window resize — the mouse-down hit one of the two
        /// resize handles on the last-interacted (frontmost) window.
        /// The frontmost is live-resized during the drag; the other
        /// selected windows are resized to match the frontmost's new
        /// dimensions on release, keeping their top-left corners fixed.
        case cornerResize(
            handle: HandleCorner,
            anchor: CGPoint,
            frontmost: ResizeSnapshot,
            others: [ResizeSnapshot]
        )
    }

    /// Which of the two visible handles the user grabbed. Determines
    /// which corner of the frontmost window is the "opposite anchor"
    /// during resize.
    private enum HandleCorner {
        /// Bottom-left handle. Top-right stays fixed.
        case bottomLeft
        /// Bottom-right handle. Top-left stays fixed.
        case bottomRight
    }

    /// Per-window state captured at cornerResize start. `axElement` is
    /// resolved eagerly so the drag update can call setPosition/setSize
    /// without re-enumerating. `originalFrame` is the pre-drag frame
    /// in Cocoa coords — needed both to anchor the resize math and to
    /// compute each "other" window's new frame at release (top-left
    /// preserved, size becomes the frontmost's final size).
    private struct ResizeSnapshot {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let originalFrame: CGRect
        let axElement: AXUIElement
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
    private var willSleepObserver: NSObjectProtocol?
    private var sessionInactiveObserver: NSObjectProtocol?

    init(selection: WindowSelection) {
        self.selection = selection
        wireEvents()
        wireIdleSafetyObservers()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        [activeSpaceObserver, willSleepObserver, sessionInactiveObserver]
            .compactMap { $0 }
            .forEach { center.removeObserver($0) }
    }

    /// Force lasso off on sleep / session-lock so the CGEventTap
    /// can't come back from a system-sleep in a stuck state.
    private func wireIdleSafetyObservers() {
        let center = NSWorkspace.shared.notificationCenter
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceLassoOffIfNeeded(reason: "system will sleep")
            }
        }
        sessionInactiveObserver = center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceLassoOffIfNeeded(reason: "session did resign active")
            }
        }
    }

    private func forceLassoOffIfNeeded(reason: String) {
        guard isLassoModeActive else { return }
        Log.lasso.notice(
            "Force-disabling lasso: \(reason, privacy: .public)"
        )
        toggleLassoMode()
    }

    // MARK: - AX-frame refresh (for cascade-during-lasso)

    /// AX element cached per selected window. Resolved when the
    /// selection changes (windows are stationary at that moment, so
    /// PID+frame matching against `AXWindowEnumerator` is reliable)
    /// and reused by `refreshSelectionOverlay` to read fresh
    /// positions directly from AX after cascade — bypassing
    /// CGWindowList, whose frame data lags AX writes by hundreds of
    /// ms for cross-app windows.
    private var axElementCache: [CGWindowID: AXUIElement] = [:]

    /// Incrementally reconciles `axElementCache` with the current
    /// selection. Called after every selection.onChange.
    ///
    /// - Existing entries for windowIDs still in the selection stay
    ///   put. AX element pointers are STABLE across window moves —
    ///   the cached element for a windowID still points to the
    ///   correct window even if the window has been teleported to
    ///   another display.
    /// - Entries for windowIDs no longer in the selection are
    ///   dropped.
    /// - Missing entries (new windowIDs added by the rubber-band)
    ///   are looked up via a fresh AX enumeration per PID, matched
    ///   by frame.
    ///
    /// The old behavior wiped the whole cache and re-matched
    /// everything on every selection change. That worked fine on
    /// the first lasso but failed after teleports: CGWindowList
    /// frames lag AX by up to 500ms, so `vw.frame` was stale, no
    /// frame match was found, and the overlay's fallback to
    /// `vw.frame` drew outlines at the pre-teleport positions —
    /// visibly offset from where the windows actually were.
    private func rebuildAXElementCache() {
        let currentIDs = Set(selection.ordered.map(\.windowID))
        // Drop stale entries first (windows removed from selection).
        for id in axElementCache.keys where !currentIDs.contains(id) {
            axElementCache.removeValue(forKey: id)
        }
        // Add missing entries via AX enumeration + frame match.
        var perPIDCache: [pid_t: [EnumeratedWindow]] = [:]
        for vw in selection.ordered where axElementCache[vw.windowID] == nil {
            let axWindows: [EnumeratedWindow]
            if let cached = perPIDCache[vw.ownerPID] {
                axWindows = cached
            } else if let app = NSRunningApplication(processIdentifier: vw.ownerPID) {
                axWindows = AXWindowEnumerator.windows(of: app)
                perPIDCache[vw.ownerPID] = axWindows
            } else {
                continue
            }
            // Match the AX element by frame within 4pt tolerance.
            // Safe for newly-added windows since the rubber-band
            // just captured them (their CGWindowList frame is fresh).
            if let match = axWindows.first(where: { rectsApproxEqual($0.frame, vw.frame, tolerance: 4) }) {
                axElementCache[vw.windowID] = match.axElement
            }
        }
    }

    /// Refreshes the selection overlay by reading each cached AX
    /// element's current position and size directly. AX reads are
    /// synchronous and reflect the app's real window state —
    /// including any move the cascade just performed. Falls back to
    /// the selection's stored Cocoa frame if an AX element is missing
    /// (e.g., window closed) or an AX read fails.
    /// Cascade fires this repeatedly (once per pass, 3-4 times over
    /// ~1.2s). We debounce here so the overlay hides on the first
    /// movement and only reappears once movements have STOPPED — the
    /// same hide-in-motion pattern used for drag/resize. Trying to
    /// keep outlines pinned to windows mid-cascade produces the
    /// exact drift the user reported.
    private var overlayReappearWorkItem: DispatchWorkItem?
    private let cascadeSettleDelay: TimeInterval = 0.35

    func refreshSelectionOverlay() {
        guard isLassoModeActive else { return }
        // Hide immediately on movement — outlines and handles both
        // disappear until motion stops.
        overlay.setSelectionFrames([])
        overlay.setFrontmostFrame(nil)

        // (Re)schedule the reappear. Each cascade pass restarts this
        // timer, so the overlay only comes back after the LAST pass
        // has landed.
        overlayReappearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reappearOverlayFromAX()
        }
        overlayReappearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cascadeSettleDelay, execute: work)
    }

    /// Reads AX-fresh frames for every selected window and rebuilds
    /// the overlay in place. Called after the cascade-settle debounce
    /// so the frames reflect where the windows actually ended up.
    /// Bails during any active drag/resize interaction so a lingering
    /// cascade timer can't cause the overlay to flash back on mid-
    /// drag (which would then invalidate the group-drag base state
    /// and produce a visible jump at the next cursor movement).
    private func reappearOverlayFromAX() {
        guard isLassoModeActive, currentDrag == nil else { return }
        // AX-fresh frame per window, keyed by CGWindowID so we can
        // reuse the same reads for BOTH the outlines and the handle
        // position. Falls back to the stored selection frame if the
        // AX read fails (e.g. app went kAXErrorAPIDisabled) or the
        // element isn't in the cache.
        var freshByID: [CGWindowID: CGRect] = [:]
        for vw in selection.ordered {
            if let element = axElementCache[vw.windowID],
               let axFrame = readAXFrame(element) {
                freshByID[vw.windowID] = CoordinateSpace.cocoaRect(fromAX: axFrame)
            } else {
                freshByID[vw.windowID] = vw.frame
            }
        }
        overlay.setSelectionFrames(selection.ordered.compactMap { freshByID[$0.windowID] })

        // Also refresh the frontmost frame so the resize handles
        // migrate with the moved window. Without this, cascade
        // during lasso leaves the handles at the pre-cascade position
        // even though the outlines correctly move to the new one.
        // Resolution order matches `frontmostVisibleWindow`: prefer
        // last-interacted (if still selected), else the z-order
        // topmost visible selected window.
        let visible = visibleSelectionWindows()
        let frontmostID: CGWindowID? = {
            if let id = selection.lastInteractedWindowID,
               visible.contains(where: { $0.windowID == id }) {
                return id
            }
            return visible.first?.windowID
        }()
        overlay.setFrontmostFrame(frontmostID.flatMap { freshByID[$0] })
    }

    /// Reads `kAXPosition` + `kAXSize` off an AX element and returns
    /// the composed AX-space CGRect. Nil if either attribute is
    /// unavailable or fails to unwrap as an AXValue.
    private func readAXFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue((posVal as! AXValue), .cgPoint, &pos)
        AXValueGetValue((sizeVal as! AXValue), .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private func rectsApproxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    /// Toggles lasso mode on/off — bound to the ⌃⌥⌘C global shortcut.
    func toggleLassoMode() {
        isLassoModeActive.toggle()
        eventMonitor.isLassoModeActive = isLassoModeActive
        // Tap only runs while lasso is on (see `setTapActive`).
        eventMonitor.setTapActive(isLassoModeActive)
        if isLassoModeActive {
            modeHint.show()
            // Browser prefetch no longer fires here — it caused
            // visible mid-drag jitter when its AppleScript
            // completion landed on the main thread. It's now
            // scheduled by `scheduleBrowserPrefetchAfterIdle()`
            // after each lasso interaction ends, targeted only to
            // browsers whose windows are in the current selection,
            // and its completion is deferred if an interaction
            // starts before the cache write can land.
        } else {
            modeHint.hide()
            cancelScheduledBrowserPrefetch()
            // Purely cosmetic: hide the on-screen lasso UI so the
            // screen matches the "off" reality. Without this, a second
            // shortcut press left the previous session's selection
            // outlines / corner handles / rubber-band rectangle drawn
            // on screen even though the event tap was already inactive,
            // producing a "lasso looks on but isn't" state. Selection
            // *data* is preserved (WindowSelection is untouched) so
            // menu commands like "Cascade Selected" and "Save to
            // Corral" still act on the retained selection. Escape
            // remains the way to fully clear data.
            overlay.hideLassoRect()
            overlay.endGroupDrag()
            overlay.setFrontmostFrame(nil)
            overlay.setSelectionFrames([])
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
        refreshOverlayAtRest()
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
        overlay.setFrontmostFrame(nil)
        overlay.endGroupDrag()
        overlayReappearWorkItem?.cancel()
        overlayReappearWorkItem = nil
        cancelScheduledBrowserPrefetch()
        BrowserScripting.deferPrefetchCommits = false
        resizeToast?.dismissNow()
        resizeToast = nil
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
            // ANY interaction — rubber-band, group drag, or corner
            // resize — cancels the pending browser prefetch and
            // tells BrowserScripting to defer any in-flight
            // completion. Complementary `markInteractionEnded()`
            // fires in `onLassoDragEnded`.
            self.markInteractionStarted()
            let vis = self.visibleSelectionWindows()

            // Hit-test PRIORITY: resize handle > selected window >
            // empty space. The handles overlap the lasso outline of
            // the frontmost window and can also overlap the window
            // itself at the bottom corners; without this priority,
            // clicking a handle would fall through to group-drag or
            // to the window's own resize edge.
            if let (handle, frontmost) = self.hitTestResizeHandle(at: point, in: vis) {
                let others = vis
                    .filter { $0.windowID != frontmost.windowID }
                    .compactMap { self.makeResizeSnapshot(for: $0) }
                self.currentDrag = .cornerResize(
                    handle: handle,
                    anchor: point,
                    frontmost: frontmost,
                    others: others
                )
                // Seed the overlay preview. During the drag the
                // frontmost outline follows the cursor via
                // `setResizePreview` on every mouseDragged; secondary
                // outlines stay at their captured original frames.
                // No AX writes occur until mouse-up — the authoritative
                // resize pipeline runs once, on release.
                var previewFrames = [frontmost.originalFrame]
                previewFrames.append(contentsOf: others.map(\.originalFrame))
                self.overlay.setResizePreview(
                    selectionFrames: previewFrames,
                    frontmostFrame: frontmost.originalFrame
                )
                Log.lasso.info(
                    "Corner resize began on window \(frontmost.windowID, privacy: .public) ('\(frontmost.ownerName, privacy: .public)') via \(handle == .bottomLeft ? "BL" : "BR", privacy: .public) — \(others.count + 1, privacy: .public) window(s) will resize on release"
                )
                return
            }

            // Hit-test: is the mouse-down over a currently-selected
            // window? If yes → M6 group drag; if no → existing
            // rubber-band lasso.
            if let hit = vis.reversed().first(where: { $0.frame.contains(point) }) {
                // Mark this window as last-interacted so the resize
                // handles migrate to it now (visible next time the
                // handles come back at rest).
                self.selection.markInteracted(hit.windowID)
                let snapshots = self.resolveSnapshots(from: vis)
                self.currentDrag = .groupDrag(
                    anchor: point,
                    primaryWindowID: hit.windowID,
                    snapshots: snapshots
                )
                // Hide outlines entirely for the duration of the drag.
                // Rather than fight AX latency to keep outlines pinned
                // to moving windows (which drifts 20–100px for slow
                // apps like Console/Chrome/Zoom under a fast drag),
                // the outlines only appear when windows are AT REST.
                // Reappearance is handled in `onLassoDragEnded` after a
                // brief settle delay so Chrome/Console have time to
                // process our final AX writes.
                // Outline-follows model: keep outlines visible during
                // the drag; each drag event calls setSelectionFrames
                // with fresh per-window frames (offset by cursor
                // delta). The overlay's updateWindow resizes the
                // panel to fit the new union — natural for cross-
                // display drags. Real windows stay put and teleport
                // into position in one AX batch at mouse-up.
                //
                // Hide the resize handles (they don't make sense
                // mid-drag) but keep the outlines rendered.
                self.overlay.setFrontmostFrame(nil)
                Log.lasso.info(
                    "Group drag began on window \(hit.windowID, privacy: .public) ('\(hit.ownerName, privacy: .public)') — \(snapshots.count, privacy: .public) window(s) will move on release"
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
            case .cornerResize(let handle, let anchor, let frontmost, let others):
                // Update the overlay outline for the frontmost window
                // and keep every other window at its captured original
                // frame. Zero AX reads, zero AX writes — the drag is
                // pure local drawing. Real resize happens once, on
                // mouse-up.
                let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                let target = Self.resizedFrame(
                    from: frontmost.originalFrame,
                    handle: handle,
                    cursorDelta: delta
                )
                var previewFrames = [target]
                previewFrames.append(contentsOf: others.map(\.originalFrame))
                self.overlay.setResizePreview(
                    selectionFrames: previewFrames,
                    frontmostFrame: target
                )
            case .groupDrag(let anchor, _, let snapshots):
                // Outline-follows model: update the overlay with
                // fresh per-window target frames every drag event.
                // The overlay redraws through its normal updateWindow
                // path, which resizes the panel to fit the current
                // union — necessary for cross-display drags where a
                // fixed-size pan panel would get clipped at the
                // display seam (leading to visibly fragmented
                // outlines).
                //
                // No AX writes fire; real windows stay put and
                // teleport at mouse-up via `onLassoDragEnded`.
                let targetDelta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                let newFrames = snapshots.map {
                    $0.originalFrame.offsetBy(dx: targetDelta.x, dy: targetDelta.y)
                }
                self.overlay.setSelectionFrames(newFrames)
            }
        }

        eventMonitor.onLassoDragEnded = { [weak self] point in
            guard let self, let drag = self.currentDrag else { return }
            // Every drag-end path below reaches its terminal switch
            // branch; regardless of branch, mark the interaction as
            // ended so any deferred prefetch results commit and the
            // idle-fire scheduler re-arms.
            defer { self.markInteractionEnded() }
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
                if delta == .zero {
                    // Click without any drag on a selected window —
                    // replace selection with just that window. Real
                    // windows never moved (nothing to teleport).
                    self.applyClick(at: anchor)
                    self.refreshOverlayAtRest()
                    Log.lasso.info(
                        "Group drag ended (click, no drag) on selected window"
                    )
                } else {
                    // Real drag: compute raw target frames, then clamp
                    // the whole group into the destination display's
                    // visible frame if the union would extend
                    // off-screen. Without this the naive delta can
                    // send windows far past the destination display's
                    // edges — macOS then clamps each window
                    // independently, and they pile up at whichever
                    // edge they hit ("windows thrown to the edge").
                    let rawTargets = snapshots.map { snap in
                        (snap: snap,
                         frame: snap.originalFrame.offsetBy(dx: delta.x, dy: delta.y))
                    }
                    let dropPoint = point
                    let dropDisplay = CoordinateSpace.screen(containing: dropPoint)
                        ?? CoordinateSpace.screen(containing: rawTargets[0].frame.origin)
                    let shift = Self.groupShiftToFit(
                        targetFrames: rawTargets.map(\.frame),
                        into: dropDisplay?.visibleFrame
                    )
                    let clampedTargets = rawTargets.map { pair in
                        (snap: pair.snap,
                         frame: pair.frame.offsetBy(dx: shift.x, dy: shift.y))
                    }

                    // Teleport all windows via parallel per-PID AX
                    // writes. Single batch at release, no jitter
                    // concern.
                    let byPID = Dictionary(grouping: clampedTargets, by: { $0.snap.ownerPID })
                    let dispatchGroup = DispatchGroup()
                    for (_, group) in byPID {
                        dispatchGroup.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            for pair in group {
                                WindowMutator.setPosition(of: pair.snap.axElement, cocoaFrame: pair.frame)
                            }
                            dispatchGroup.leave()
                        }
                    }
                    dispatchGroup.wait()

                    // Read-back + one retry for any window that
                    // silently failed to move. AX writes can return
                    // success but the app rejects them (Chrome mid-
                    // repaint, Console during log render, etc.). One
                    // retry after a small delay catches most
                    // transient failures. Without this, occasional
                    // drags leave outlines at rest while real
                    // windows stayed put — visibly broken.
                    Self.retryFailedTeleports(clampedTargets, tolerance: 4)

                    // Refresh overlay to settled positions using the
                    // AX-cache path (fresh) rather than CGWindowList
                    // (which lags AX writes by 200-500ms). Note we
                    // call `refreshOverlayAtRest` directly here,
                    // NOT `refreshSelectionOverlay` — the latter is
                    // the cascade-debounce entry point that HIDES
                    // the overlay for 350ms before reappearing,
                    // which would look like the outlines briefly
                    // vanishing and then re-appearing offset.
                    let settleDelay: TimeInterval = 0.20
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                        self?.refreshOverlayAtRest()
                    }
                    Log.lasso.info(
                        "Group drag ended; teleported \(snapshots.count, privacy: .public) window(s) by (\(Int(delta.x + shift.x), privacy: .public),\(Int(delta.y + shift.y), privacy: .public)) — clamp shift (\(Int(shift.x), privacy: .public),\(Int(shift.y), privacy: .public))"
                    )
                }
            case .cornerResize(let handle, let anchor, let frontmost, let others):
                let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
                let frontmostTarget = Self.resizedFrame(
                    from: frontmost.originalFrame,
                    handle: handle,
                    cursorDelta: delta
                )
                // Authoritative final write to the frontmost using the
                // exact mouse-up point. The drag itself never touched
                // any real window (overlay preview only), so this is
                // the first and only mid-gesture AX write for the
                // frontmost.
                WindowMutator.setFrame(frontmostTarget, of: frontmost.axElement)

                // Compute each OTHER window's target frame: same
                // dimensions as the frontmost, but keep its own
                // top-left corner fixed. Skip windows that AX refuses
                // to resize, and windows whose new frame would push
                // off-screen.
                // Track skipped windows by windowID (not ownerName). Two
                // windows of the same app can have different outcomes —
                // one may be resizable while another (e.g. an Info panel
                // vs. a browser window under Finder) refuses. Filtering
                // by name later would drop BOTH from the auto-cascade
                // whenever any single window of an app failed.
                var skippedIDs: Set<CGWindowID> = []
                var toApply: [ResizeSnapshot] = []
                let targetSize = frontmostTarget.size
                for snap in others {
                    if !WindowMutator.isSizeSettable(snap.axElement) {
                        skippedIDs.insert(snap.windowID)
                        continue
                    }
                    let newFrame = Self.resizedFrameKeepingTopLeft(
                        of: snap.originalFrame,
                        to: targetSize
                    )
                    if !Self.frameFitsOnScreen(newFrame) {
                        skippedIDs.insert(snap.windowID)
                        continue
                    }
                    toApply.append(snap)
                }

                // Apply the writes for the "other" windows in
                // parallel per PID (same pattern as group drag).
                let byPID = Dictionary(grouping: toApply, by: \.ownerPID)
                let dispatchGroup = DispatchGroup()
                for (_, groupSnaps) in byPID {
                    dispatchGroup.enter()
                    DispatchQueue.global(qos: .userInteractive).async {
                        for snap in groupSnaps {
                            let newFrame = Self.resizedFrameKeepingTopLeft(
                                of: snap.originalFrame,
                                to: targetSize
                            )
                            WindowMutator.setFrame(newFrame, of: snap.axElement)
                        }
                        dispatchGroup.leave()
                    }
                }
                dispatchGroup.wait()

                // Refresh overlay + handles after apps settle, then
                // read back to detect clamps (apps like Xcode may
                // accept the write but bounce back to their own
                // minimum) and toast the combined skip/clamp list.
                // Also fires the auto-cascade callback: after a
                // multi-window resize the fan geometry no longer fits
                // the new size, so re-cascade preserves the fan
                // pattern the user was already working with.
                //
                // 100ms is enough padding for most apps to finish
                // clamping (empirically 50–80ms on Chrome/System
                // Settings, the slowest we see). 200ms was safety
                // margin that showed up as a visible post-release
                // pause before the fan appeared. If we ever catch a
                // mid-clamp size, the cascade uses `preserveWindowSizes`
                // (no size writes) so the worst case is ~1–2pt off,
                // not visible.
                let settleDelay: TimeInterval = 0.10
                let frontmostSnapshot = frontmost
                let othersSnapshots = others
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                    guard let self else { return }
                    self.refreshOverlayAtRest()
                    let clampedIDs = self.detectClampedWindowIDs(
                        toApply: toApply,
                        target: targetSize
                    )
                    let allSkippedIDs = skippedIDs.union(clampedIDs)
                    // Toast wants a deduped, sorted list of APP names —
                    // "Xcode kept original size" reads better than
                    // "one Xcode window kept original size". Deriving
                    // names from IDs here (instead of collecting names
                    // above) keeps the per-window filter authoritative
                    // and the display concerns local to this hop.
                    if !allSkippedIDs.isEmpty {
                        let names = othersSnapshots
                            .filter { allSkippedIDs.contains($0.windowID) }
                            .map(\.ownerName)
                        let uniqueNames = Array(Set(names)).sorted()
                        let resized = (others.count + 1) - allSkippedIDs.count
                        self.showResizeToast(
                            resizedCount: resized,
                            skippedNames: uniqueNames
                        )
                    }
                    // Auto-cascade — frontmost first so the cascade
                    // math uses its size as the slot target. Include
                    // EVERY window in the selection, even ones that
                    // refused the resize or clamped: cascade already
                    // handles narrow-in-slot layout (right-alignment)
                    // and the user's whole selection should rearrange
                    // together after a resize gesture — leaving four
                    // scattered windows in place while the other six
                    // fan out looks like the cascade never fired.
                    // Parallel AX reads — each `readFreshEnumeratedWindow`
                    // is a cross-app AX IPC blocked on the target app's
                    // runloop (~5–8ms each). Serially across 9+ windows
                    // that's ~50–70ms of dead time on the main thread
                    // between mouseUp settle and cascade fire. Running
                    // them concurrently drops the whole batch to roughly
                    // one AX round-trip.
                    //
                    // Safety: `readFreshEnumeratedWindow` is nonisolated
                    // and touches no shared mutable state. Each
                    // iteration writes to a distinct buffer index via
                    // `UnsafeMutableBufferPointer`, so there's no data
                    // race on the results collection.
                    let allSnapshots: [ResizeSnapshot] = [frontmostSnapshot] + othersSnapshots
                    var freshResults = [EnumeratedWindow?](repeating: nil, count: allSnapshots.count)
                    freshResults.withUnsafeMutableBufferPointer { buffer in
                        DispatchQueue.concurrentPerform(iterations: allSnapshots.count) { i in
                            buffer[i] = self.readFreshEnumeratedWindow(from: allSnapshots[i])
                        }
                    }
                    let cascadeList = freshResults.compactMap { $0 }
                    if cascadeList.count > 1 {
                        self.onResizeCompleted?(cascadeList, targetSize)
                    }
                }

                Log.lasso.info(
                    "Corner resize ended; frontmost now \(Int(frontmostTarget.width), privacy: .public)×\(Int(frontmostTarget.height), privacy: .public), applied to \(toApply.count, privacy: .public) other(s), skipped \(skippedIDs.count, privacy: .public) pre-flight"
                )
            }
            self.currentDrag = nil
        }

        eventMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            self.cancelScheduledBrowserPrefetch()
            BrowserScripting.deferPrefetchCommits = false
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
                    // If the drag was a corner resize, no real window
                    // was touched — the drag is overlay-preview-only,
                    // so Escape just drops the preview. Group drag is
                    // live and stops where cancelled; no restore
                    // needed there either.
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
        // Also rebuild the AX-element cache so `refreshSelectionOverlay`
        // has fresh AX references to read positions from after cascade,
        // and refresh the resize-handle position (the frontmost's
        // bottom corners) since it depends on the selection.
        selection.onChange = { [weak self] in
            guard let self else { return }
            self.rebuildAXElementCache()
            self.refreshOverlayAtRest()
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
                // Skip teardown during an active group drag — with
                // "Displays have separate Spaces" enabled, macOS
                // fires this notification when the cursor crosses a
                // display boundary mid-drag; destroying the overlay
                // panel here would visibly detach the outlines and
                // invalidate group-drag base state.
                if self.currentDrag != nil { return }
                // Destroy the old overlay panel (it's pinned to the
                // previous Space and already animated off). The next
                // frame-setting call recreates a fresh panel on the
                // now-active Space.
                self.overlay.spaceDidChange()
                self.overlay.setSelectionFrames(self.visibleSelectionFrames())
            }
        }
    }

    // (Cross-display proxy handoff experiment removed after testing
    // showed it introduced worse behavior — edge-stacking and
    // continued jitter — than the pre-experiment path. Group drag
    // reverts to the 851c1df behavior: parallel-per-PID AX writes,
    // hide outlines during drag, skip window-frame exception mid-
    // drag, skip space-change teardown mid-drag. Cross-display drag
    // with "Displays have separate Spaces" enabled remains
    // AX-inherently jittery — same class of issue as the M6 outline
    // drift limitation.)

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
        var snapshots: [GroupDragSnapshot] = []
        snapshots.reserveCapacity(visible.count)
        // AX-element cache from earlier selection changes (keyed by
        // CGWindowID). Preferred over re-matching because it's O(1)
        // and never wrong — AX element pointers are stable across
        // window moves, so a cached element for a windowID still
        // points to the same window even if it moved.
        for vw in visible {
            let element: AXUIElement?
            if let cached = axElementCache[vw.windowID] {
                element = cached
            } else if let app = NSRunningApplication(processIdentifier: vw.ownerPID) {
                let axWindows = AXWindowEnumerator.windows(of: app)
                element = axWindows.first(where: {
                    Self.framesApproximatelyEqual($0.frame, vw.frame, tolerance: 4)
                })?.axElement
            } else {
                element = nil
            }
            guard let ax = element else { continue }
            // Read the window's ACTUAL current frame via AX rather
            // than trusting `vw.frame` (which comes from CGWindowList
            // and lags AX writes by up to 500ms). Without this, rapid
            // successive drags built their originalFrame from
            // stale CGWindowList data — the outline started at the
            // stale position and the teleport landed at a stale-
            // relative offset from the cursor, so outlines and
            // windows visibly diverged after every few drags.
            let currentCocoa: CGRect
            if let axFrame = AXWindowEnumerator.currentFrame(of: ax) {
                currentCocoa = CoordinateSpace.cocoaRect(fromAX: axFrame)
            } else {
                currentCocoa = vw.frame  // AX read failed — best-effort fall back
            }
            snapshots.append(GroupDragSnapshot(
                windowID: vw.windowID,
                ownerPID: vw.ownerPID,
                originalFrame: currentCocoa,
                axElement: ax
            ))
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

    // MARK: - Multi-window resize helpers

    /// Frame of the frontmost selected window in Cocoa global coords,
    /// if the selection contains any visible ones. Used to position
    /// the resize handles.
    ///
    /// Preference: the last-interacted window (a real user signal —
    /// "the one I most recently touched"). Fallback: the visually
    /// topmost of the visible selected windows, which is what a user
    /// would naturally think of as "the frontmost one" before they've
    /// interacted with anything.
    private func currentFrontmostFrame() -> CGRect? {
        frontmostVisibleWindow(in: visibleSelectionWindows())?.frame
    }

    /// Refreshes the overlay at rest. Reads each selected window's
    /// AX-fresh frame when possible (via `axElementCache`), falling
    /// back to the CGWindowList frame stored on `VisibleWindow` when
    /// AX isn't available (e.g. the cache hasn't been built yet
    /// right after the initial rubber-band).
    ///
    /// Using AX-fresh frames matters because CGWindowList lags AX
    /// writes by 200–500ms for cross-app windows. When we refresh
    /// the overlay right after a teleport (or right after a fast
    /// sequence of drags), stale CGWindowList data would draw the
    /// outlines at the previous positions — visible as "outlines
    /// offset from windows."
    private func refreshOverlayAtRest() {
        // Per-window fresh frames, keyed so we can reuse for both
        // the outline list and the frontmost handle position.
        var freshByID: [CGWindowID: CGRect] = [:]
        var cacheHits = 0
        var axFailures = 0
        for vw in selection.ordered {
            if let element = axElementCache[vw.windowID],
               let axFrame = readAXFrame(element) {
                freshByID[vw.windowID] = CoordinateSpace.cocoaRect(fromAX: axFrame)
                cacheHits += 1
            } else {
                // Fall back to CGWindowList frame from the selection
                // model. Only expected for the first-lasso case; if
                // this fires post-teleport it means the AX cache is
                // missing an entry (bug) or AX read failed on that
                // window (transient).
                freshByID[vw.windowID] = vw.frame
                axFailures += 1
            }
        }
        if axFailures > 0 {
            Log.lasso.notice(
                "refreshOverlayAtRest — \(cacheHits, privacy: .public) AX-fresh, \(axFailures, privacy: .public) CGWindowList-fallback (may be visibly offset)"
            )
        }
        overlay.setSelectionFrames(selection.ordered.compactMap { freshByID[$0.windowID] })
        // Frontmost frame for handles: same source, same freshness.
        let visible = visibleSelectionWindows()
        let frontmostID: CGWindowID? = {
            if let id = selection.lastInteractedWindowID,
               visible.contains(where: { $0.windowID == id }) {
                return id
            }
            return visible.first?.windowID
        }()
        overlay.setFrontmostFrame(frontmostID.flatMap { freshByID[$0] })
    }

    /// Which visible selected window currently hosts the resize
    /// handles. Prefers `lastInteractedWindowID`; falls back to the
    /// z-order-frontmost of the visible selection. Kept as a single
    /// function so hit-testing and rendering always agree.
    private func frontmostVisibleWindow(in visible: [VisibleWindow]) -> VisibleWindow? {
        if let id = selection.lastInteractedWindowID,
           let vw = visible.first(where: { $0.windowID == id }) {
            return vw
        }
        return visible.first
    }

    /// Hit-tests the given global-coords point against the two resize
    /// handles rendered on the frontmost window's bottom corners.
    /// Returns the handle and the resolved snapshot for it if hit,
    /// nil otherwise. Uses `handleHitRadius` (larger than the visible
    /// circle) so grabbing feels forgiving.
    private func hitTestResizeHandle(
        at point: CGPoint,
        in visible: [VisibleWindow]
    ) -> (HandleCorner, ResizeSnapshot)? {
        guard let frontmostVW = frontmostVisibleWindow(in: visible),
              let snapshot = makeResizeSnapshot(for: frontmostVW) else {
            return nil
        }
        let frame = frontmostVW.frame
        let radius = SelectionOverlay.handleHitRadius
        let bl = CGPoint(x: frame.minX, y: frame.minY)
        let br = CGPoint(x: frame.maxX, y: frame.minY)
        if hypot(point.x - bl.x, point.y - bl.y) <= radius {
            return (.bottomLeft, snapshot)
        }
        if hypot(point.x - br.x, point.y - br.y) <= radius {
            return (.bottomRight, snapshot)
        }
        return nil
    }

    /// Resolves a VisibleWindow into a ResizeSnapshot by matching the
    /// window's frame against the app's AX children within 4pt.
    /// Returns nil if the running app is gone or no AX match is found.
    private func makeResizeSnapshot(for vw: VisibleWindow) -> ResizeSnapshot? {
        guard let app = NSRunningApplication(processIdentifier: vw.ownerPID) else {
            return nil
        }
        let axWindows = AXWindowEnumerator.windows(of: app)
        guard let match = axWindows.first(where: {
            Self.framesApproximatelyEqual($0.frame, vw.frame, tolerance: 4)
        }) else { return nil }
        return ResizeSnapshot(
            windowID: vw.windowID,
            ownerPID: vw.ownerPID,
            ownerName: vw.ownerName,
            originalFrame: vw.frame,
            axElement: match.axElement
        )
    }

    /// Computes the frontmost window's new frame during resize.
    /// BL handle: top-right anchored; BR handle: top-left anchored.
    /// Enforces a small minimum size (140×80) so the user can't
    /// collapse a window to zero — most apps ignore sub-minimum
    /// writes anyway, but the outline was catastrophically ugly
    /// without a floor.
    private static func resizedFrame(
        from original: CGRect,
        handle: HandleCorner,
        cursorDelta: CGPoint
    ) -> CGRect {
        let minW: CGFloat = 140
        let minH: CGFloat = 80
        switch handle {
        case .bottomLeft:
            // Top-right stays fixed. dx>0 shrinks width, dy>0 (up in
            // Cocoa) shrinks height. Cursor moves = delta = point - anchor.
            let newWidth = max(minW, original.width - cursorDelta.x)
            let newHeight = max(minH, original.height - cursorDelta.y)
            let topRight = CGPoint(x: original.maxX, y: original.maxY)
            return CGRect(
                x: topRight.x - newWidth,
                y: topRight.y - newHeight,
                width: newWidth,
                height: newHeight
            )
        case .bottomRight:
            // Top-left stays fixed. dx>0 grows width, dy>0 (up in
            // Cocoa) shrinks height.
            let newWidth = max(minW, original.width + cursorDelta.x)
            let newHeight = max(minH, original.height - cursorDelta.y)
            let topLeft = CGPoint(x: original.minX, y: original.maxY)
            return CGRect(
                x: topLeft.x,
                y: topLeft.y - newHeight,
                width: newWidth,
                height: newHeight
            )
        }
    }

    /// Computes a window's new frame given a target size, keeping its
    /// top-left corner fixed. Used for the "others" windows when the
    /// frontmost resize applies to the whole selection at release —
    /// per the spec, positions are unchanged, only sizes.
    ///
    /// `nonisolated` so it can be called from the background
    /// per-PID dispatch in the release path without hopping to the
    /// main actor. Pure math — no shared state, no side effects.
    nonisolated private static func resizedFrameKeepingTopLeft(
        of original: CGRect,
        to targetSize: CGSize
    ) -> CGRect {
        let topLeft = CGPoint(x: original.minX, y: original.maxY)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    /// True if the given target frame's title bar and body would
    /// remain onscreen (visible-frame of the display it primarily
    /// occupies). We only guard the two edges that can grow past the
    /// display when keeping top-left fixed: the RIGHT edge and the
    /// BOTTOM edge.
    private static func frameFitsOnScreen(_ frame: CGRect) -> Bool {
        guard let screen = CoordinateSpace.screen(containing: frame) else {
            return false
        }
        let visible = screen.visibleFrame
        // Allow a small tolerance so a 1-2pt hairline overhang doesn't
        // trigger a skip — apps often render slightly larger than the
        // requested content rect.
        let tolerance: CGFloat = 4
        if frame.maxX > visible.maxX + tolerance { return false }
        if frame.minY < visible.minY - tolerance { return false }
        return true
    }

    /// Reads the current AX frame for a resize snapshot's element and
    /// wraps it in an `EnumeratedWindow` for the cascade path. Nil
    /// if the AX read fails (element pointer went stale, app died).
    ///
    /// `nonisolated` because the body touches no actor state — just an
    /// AX IPC and a pure coordinate conversion. Callers (specifically
    /// the batched post-resize read below) use `concurrentPerform` to
    /// run several instances of this in parallel across the AX
    /// dispatcher; each one is otherwise ~5–8ms of blocked wait.
    nonisolated private func readFreshEnumeratedWindow(from snap: ResizeSnapshot) -> EnumeratedWindow? {
        guard let axFrame = AXWindowEnumerator.currentFrame(of: snap.axElement) else {
            return nil
        }
        return EnumeratedWindow(
            axElement: snap.axElement,
            frame: CoordinateSpace.cocoaRect(fromAX: axFrame)
        )
    }

    /// After a resize, reads back each attempted window's actual size
    /// and returns the IDs of any that ended up meaningfully different
    /// from the target (>4pt difference in either dimension). These are
    /// windows the app "accepted" the write on but clamped to its own
    /// minimum — Xcode, some IDEs, Terminal.
    ///
    /// Returns IDs (not names) so the caller can filter per-window: two
    /// windows of the same app may have different outcomes, and filtering
    /// by name drops both from the auto-cascade whenever any one clamps.
    private func detectClampedWindowIDs(
        toApply: [ResizeSnapshot],
        target: CGSize
    ) -> Set<CGWindowID> {
        var clamped: Set<CGWindowID> = []
        for snap in toApply {
            guard let actualAX = AXWindowEnumerator.currentFrame(of: snap.axElement) else { continue }
            let actual = CoordinateSpace.cocoaRect(fromAX: actualAX)
            if abs(actual.width - target.width) > 4 || abs(actual.height - target.height) > 4 {
                clamped.insert(snap.windowID)
            }
        }
        return clamped
    }

    /// Shows the resize-result toast when at least one window was
    /// skipped or clamped. Reuses the CorralToast panel style.
    /// Longer hold than default so the app-name list is readable.
    private var resizeToast: CorralToast?
    private func showResizeToast(resizedCount: Int, skippedNames: [String]) {
        // "3 windows resized. Xcode and Console kept original size."
        let joined: String
        if skippedNames.count == 1 {
            joined = skippedNames[0]
        } else if skippedNames.count == 2 {
            joined = "\(skippedNames[0]) and \(skippedNames[1])"
        } else {
            let head = skippedNames.dropLast().joined(separator: ", ")
            joined = "\(head), and \(skippedNames.last!)"
        }
        let noun = resizedCount == 1 ? "window" : "windows"
        let text = "\(resizedCount) \(noun) resized. \(joined) kept original size."
        resizeToast?.dismissNow()
        let toast = CorralToast()
        toast.showMessage(text, style: .success, holdSeconds: 3.5) { [weak self] in
            self?.resizeToast = nil
        }
        resizeToast = toast
    }


    // MARK: - Idle-aware browser prefetch

    /// Cancellable pending prefetch. Reset every time an interaction
    /// starts (so a completion can't land mid-drag) and re-armed
    /// each time an interaction ends.
    private var browserPrefetchWorkItem: DispatchWorkItem?

    /// How long the app must be idle after an interaction before
    /// firing the browser prefetch. Long enough that a rapid follow-
    /// up drag cancels it; short enough that Corral save (typically
    /// several seconds after a lasso ends) finds a warm cache.
    private let browserPrefetchIdleDelay: TimeInterval = 0.75

    /// Returns bundle IDs of currently-selected windows whose owning
    /// app is a supported browser. Used to target the prefetch —
    /// no point warming a browser cache if the user hasn't selected
    /// any browser windows.
    private func selectedBrowserBundleIDs() -> Set<String> {
        var ids: Set<String> = []
        for vw in selection.ordered {
            guard let app = NSRunningApplication(processIdentifier: vw.ownerPID),
                  let bundleID = app.bundleIdentifier,
                  BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { continue }
            ids.insert(bundleID)
        }
        return ids
    }

    /// Cancels any pending browser prefetch. Safe no-op when nothing
    /// is pending. Also called by the "interaction starts" hooks so
    /// a pending prefetch can never fire during a drag.
    private func cancelScheduledBrowserPrefetch() {
        browserPrefetchWorkItem?.cancel()
        browserPrefetchWorkItem = nil
    }

    /// Schedules a browser prefetch to fire after
    /// `browserPrefetchIdleDelay` seconds of no new interaction.
    /// Cancels any previously-scheduled prefetch first so timers
    /// don't stack. Also enters `BrowserScripting.deferPrefetchCommits
    /// = false` — future completions can land normally.
    private func scheduleBrowserPrefetchAfterIdle() {
        cancelScheduledBrowserPrefetch()
        guard isLassoModeActive else { return }
        let bundleIDs = selectedBrowserBundleIDs()
        guard !bundleIDs.isEmpty else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isLassoModeActive,
                  self.currentDrag == nil else {
                return
            }
            BrowserScripting.prefetchBrowsers(bundleIDs: bundleIDs)
        }
        browserPrefetchWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + browserPrefetchIdleDelay,
            execute: work
        )
    }

    /// Called at every interaction-start point (rubber-band, group
    /// drag, corner resize). Cancels any pending prefetch and tells
    /// BrowserScripting to defer any in-flight completion's cache
    /// write until the interaction ends. This is the anti-jitter
    /// bit: without it, an AppleScript completion arriving mid-drag
    /// would stall the overlay redraw for ~10-30ms and produce
    /// visible position jumps on cross-display transit.
    private func markInteractionStarted() {
        cancelScheduledBrowserPrefetch()
        BrowserScripting.deferPrefetchCommits = true
    }

    /// Called at every interaction-end point. Flushes any deferred
    /// prefetch results to the cache, clears the defer flag, and
    /// schedules the next idle-triggered prefetch.
    private func markInteractionEnded() {
        BrowserScripting.deferPrefetchCommits = false
        BrowserScripting.flushPendingPrefetchResults()
        scheduleBrowserPrefetchAfterIdle()
    }

    // MARK: - Group drag helpers

    /// Reads back each teleported window's actual AX frame and
    /// retries `setPosition` for any that landed outside `tolerance`
    /// of the intended target. One retry only — enough for the
    /// common transient-rejection case (app was mid-repaint, AX
    /// silently no-op'd the write) without stalling on genuinely
    /// unresizable windows.
    ///
    /// Runs synchronously — brief since it's just a handful of AX
    /// reads and (usually) zero writes. Called from the release
    /// path AFTER the parallel dispatch group returns, so we know
    /// the first-pass writes have all been issued.
    nonisolated private static func retryFailedTeleports(
        _ targets: [(snap: GroupDragSnapshot, frame: CGRect)],
        tolerance: CGFloat
    ) {
        // Give apps a moment to process the initial write burst.
        // 40ms is enough for most apps; longer would push into
        // the settle window and hurt UI responsiveness.
        Thread.sleep(forTimeInterval: 0.040)
        for pair in targets {
            guard let axFrame = AXWindowEnumerator.currentFrame(of: pair.snap.axElement) else {
                continue
            }
            let actual = CoordinateSpace.cocoaRect(fromAX: axFrame)
            if abs(actual.origin.x - pair.frame.origin.x) > tolerance
                || abs(actual.origin.y - pair.frame.origin.y) > tolerance {
                // Failed — retry once.
                WindowMutator.setPosition(of: pair.snap.axElement, cocoaFrame: pair.frame)
            }
        }
    }

    /// Computes an (x, y) shift to apply to every target frame so
    /// the group's bounding-box union fits inside `visibleFrame`.
    /// Preserves group cohesion — every window moves by the same
    /// shift. Zero shift if union already fits or if the union is
    /// wider/taller than the destination display (in which case
    /// there's no shift that would fit — we accept overflow rather
    /// than deform the group).
    ///
    /// This is what prevents "windows thrown to the edge" on a
    /// cross-display teleport where the raw delta would push some
    /// windows past the destination display's boundaries.
    nonisolated static func groupShiftToFit(
        targetFrames: [CGRect],
        into visibleFrame: CGRect?
    ) -> CGPoint {
        guard let visible = visibleFrame, !targetFrames.isEmpty else {
            return .zero
        }
        // Compute union of target frames.
        var union = targetFrames[0]
        for f in targetFrames.dropFirst() {
            union = union.union(f)
        }
        // If group is bigger than display in either dimension, we
        // can't shift it in — just leave it (best-effort).
        var shiftX: CGFloat = 0
        var shiftY: CGFloat = 0
        if union.width <= visible.width {
            if union.maxX > visible.maxX {
                shiftX = visible.maxX - union.maxX  // negative
            } else if union.minX < visible.minX {
                shiftX = visible.minX - union.minX  // positive
            }
        }
        if union.height <= visible.height {
            if union.maxY > visible.maxY {
                shiftY = visible.maxY - union.maxY
            } else if union.minY < visible.minY {
                shiftY = visible.minY - union.minY
            }
        }
        return CGPoint(x: shiftX, y: shiftY)
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

