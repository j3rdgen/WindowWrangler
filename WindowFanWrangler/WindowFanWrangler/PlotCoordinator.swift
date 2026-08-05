//
//  PlotCoordinator.swift
//  Window Wrangler
//
//  Owns Plot Mode: single-window precision placement.
//
//  Flow:
//    inactive → awaitingWindow → windowSelected → pendingGesture
//    → drawingPlot → committing → awaitingWindow (loop)
//    → inactive (on Escape or shortcut toggle)
//
//  Interacts with:
//   - GlobalEventMonitor (shares the tap; mutually exclusive with Lasso)
//   - CrossAppWindowEnumerator (front-to-back hit-test)
//   - AXWindowEnumerator (AX element resolution via frame match)
//   - WindowMutator (single-window setFrame / setPosition / raise)
//   - PlotOverlay (selection outline, preview, landing pulse)
//   - PlotModeHint (persistent "Press Esc to End Plot Mode" pill)
//   - PlotGeometry (pure snap + normalization + validation)
//
//  Does NOT interact with any cascade / group / lasso mutation path.
//  A plotted window is moved independently — no other window moves.
//

import AppKit
import ApplicationServices
import os

@MainActor
final class PlotCoordinator {

    // MARK: - Feature flags
    //
    // Independently switchable — set to `false` to restore exact
    // prior behavior. Kept per-file (matching CascadeOrchestrator's
    // Stage flag convention) rather than globalized so the rollback
    // is a single-line edit here.

    /// When true, supported Chromium Plot targets commit via
    /// `BrowserScripting.setBrowserWindowBoundsNearFrame` (AppleScript
    /// `bounds` write), which persists where AX size writes revert.
    /// When false, every Plot commit uses the existing pure-AX flow
    /// — Chromium windows will position correctly but retain their
    /// own preferred size, matching the previous behavior exactly.
    private let useBrowserNativeBoundsForPlot = true

    /// Settling delay between the native bounds write and the
    /// authoritative AX readback. 200ms is long enough for Chrome
    /// to finish its own layout pass but short enough that the
    /// landing pulse still feels immediate. Named constant per
    /// spec — do not inline.
    private let plotNativeSettleDelay: TimeInterval = 0.20

    // MARK: - Injected collaborators

    private let eventMonitor: GlobalEventMonitor
    private let hint = PlotModeHint()
    private let overlay = PlotOverlay()
    private let isTrusted: () -> Bool

    /// Fired whenever Plot Mode toggles on/off. Used by the app
    /// delegate to rebuild the menu.
    var onPlotModeChanged: ((Bool) -> Void)?

    /// Fired the moment Plot Mode is turned on so the caller can
    /// tear down any conflicting mode (Lasso) BEFORE Plot starts
    /// receiving events. Returns synchronously.
    var willActivate: (() -> Void)?

    // MARK: - State machine

    struct PlotSelection {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        /// Owning app's bundle identifier if resolvable, nil otherwise.
        /// Captured at selection time so the commit path can decide
        /// transport (native vs. AX) without a second
        /// `NSRunningApplication` lookup on the hot path.
        let bundleID: String?
        /// Frame at the time of selection, in Cocoa global coords.
        /// Refreshed just before commit via AX read.
        let capturedFrame: CGRect
        /// Resolved once at selection time so the commit step can
        /// mutate without another AX enumeration.
        let axElement: AXUIElement
    }

    enum State {
        case inactive
        case awaitingWindow
        case windowSelected(PlotSelection)
        case pendingGesture(
            selection: PlotSelection,
            mouseDown: CGPoint,
            controlHeld: Bool
        )
        case drawingPlot(
            selection: PlotSelection,
            dragStart: CGPoint,
            targetScreen: NSScreen,
            snap: PlotSnapState
        )
        case committing
    }

    private(set) var state: State = .inactive

    /// Snapshot of the last committed Plot Area. Purely diagnostic.
    private var lastCommittedFrame: CGRect?

    /// Increments on every teardown so scheduled work (retry writes,
    /// display-change handlers) can bail if the mode was ended.
    private var generation: UInt64 = 0

    // MARK: - Init

    init(eventMonitor: GlobalEventMonitor, isTrusted: @escaping () -> Bool) {
        self.eventMonitor = eventMonitor
        self.isTrusted = isTrusted
        wireEvents()
        wireScreenChangeObserver()
    }

    // MARK: - Public state

    var isPlotModeActive: Bool {
        if case .inactive = state { return false }
        return true
    }

    // MARK: - Mode lifecycle

    /// Toggles Plot Mode on / off. Bound to `⌃⌥⌘P` and the menu
    /// item. Turning on tears down any conflicting mode via the
    /// `willActivate` hook first. Turning off runs the same complete
    /// teardown as Escape.
    func togglePlotMode() {
        if isPlotModeActive {
            endPlotMode()
        } else {
            startPlotMode()
        }
    }

    /// Ends Plot Mode completely. Same code path as Escape and the
    /// second shortcut press. Idempotent — safe to call from any
    /// mode-arbitration site.
    func endPlotMode() {
        guard isPlotModeActive else { return }
        generation &+= 1
        state = .inactive
        eventMonitor.isPlotModeActive = false
        // Only disable the tap if lasso isn't holding it on.
        if !eventMonitor.isLassoModeActive {
            eventMonitor.setTapActive(false)
        }
        overlay.clearAll()
        hint.hideImmediately()
        Log.plot.notice("Plot mode: OFF (teardown complete)")
        onPlotModeChanged?(false)
    }

    private func startPlotMode() {
        // Preflight: AX permission required for both selection
        // (AX element resolution) and commit (AX writes).
        guard isTrusted() else {
            Log.plot.error("Plot mode start aborted — AX permission not granted")
            return
        }
        // Let the app delegate tear down any conflicting mode first.
        willActivate?()
        generation &+= 1
        state = .awaitingWindow
        eventMonitor.isPlotModeActive = true
        eventMonitor.setTapActive(true)
        hint.show()
        overlay.clearAll()
        Log.plot.notice("Plot mode: ON (awaitingWindow)")
        onPlotModeChanged?(true)
    }

    // MARK: - Event routing

    private func wireEvents() {
        // Plot has its own mouse callback set on GlobalEventMonitor
        // so Lasso's callbacks stay untouched. Both modes never run
        // simultaneously (arbitration in WindowWranglerApp).
        eventMonitor.onPlotMouseDown = { [weak self] point, flags in
            self?.handleMouseDown(at: point, flags: flags)
        }
        eventMonitor.onPlotMouseDragged = { [weak self] point in
            self?.handleMouseDragged(to: point)
        }
        eventMonitor.onPlotMouseUp = { [weak self] point in
            self?.handleMouseUp(at: point)
        }
        // Escape end: share with Lasso via the same escape callback.
        // WindowWranglerApp wires escape to both.
    }

    /// Called by the app delegate's escape router when Plot is active.
    /// Escape from ANY active Plot state → inactive (same as toggle-off).
    func handleEscape() {
        guard isPlotModeActive else { return }
        Log.plot.notice("Escape pressed — ending Plot mode")
        endPlotMode()
    }

    // MARK: - Mouse handlers

    private func handleMouseDown(at point: CGPoint, flags: CGEventFlags) {
        let controlHeld = flags.contains(.maskControl)
        switch state {
        case .inactive:
            return
        case .awaitingWindow:
            // First-click selection. Resolve window under cursor.
            attemptSelection(at: point)
        case .windowSelected(let selection):
            // Second mouse-down enters pending gesture. Whether this
            // becomes a Plot draw, a Control-click reselection, or a
            // no-op is decided at mouseUp / threshold-cross.
            state = .pendingGesture(
                selection: selection,
                mouseDown: point,
                controlHeld: controlHeld
            )
        case .pendingGesture, .drawingPlot, .committing:
            // Extra mouse-downs during pending/drawing are ignored;
            // the event tap won't normally deliver a second down
            // without an intervening up, but the guard is cheap.
            return
        }
    }

    private func handleMouseDragged(to point: CGPoint) {
        switch state {
        case .inactive, .awaitingWindow, .windowSelected, .committing:
            return
        case .pendingGesture(let selection, let mouseDown, _):
            guard PlotGeometry.exceedsDragThreshold(from: mouseDown, to: point) else {
                return
            }
            // Lock the target display from the ORIGINAL mouse-down
            // point. Once locked, we never switch even if the pointer
            // crosses a seam.
            guard let screen = CoordinateSpace.screen(containing: mouseDown) else {
                Log.plot.info("Drag threshold crossed but mouse-down had no display — staying in windowSelected")
                state = .windowSelected(selection)
                return
            }
            state = .drawingPlot(
                selection: selection,
                dragStart: mouseDown,
                targetScreen: screen,
                snap: .none
            )
            Log.plot.info("Drag threshold crossed — targetScreen=\(screen.plotShortDescription, privacy: .public)")
            updateDrawingPreview(currentPoint: point)
        case .drawingPlot:
            updateDrawingPreview(currentPoint: point)
        }
    }

    private func handleMouseUp(at point: CGPoint) {
        switch state {
        case .inactive, .awaitingWindow, .committing:
            return
        case .windowSelected:
            // Stray mouseUp with no matching down (shouldn't happen
            // via the tap, but be safe).
            return
        case .pendingGesture(let selection, let mouseDown, let controlHeld):
            // Never reached drag threshold. If Control was held,
            // interpret as a reselection click; otherwise no-op.
            if controlHeld {
                attemptControlClickReselection(currentSelection: selection, at: point)
            } else {
                // Retain existing target. No context menu.
                state = .windowSelected(selection)
            }
            _ = mouseDown
        case .drawingPlot(let selection, let dragStart, let screen, _):
            commitDrawnPlot(
                selection: selection,
                dragStart: dragStart,
                mouseUp: point,
                screen: screen
            )
        }
    }

    // MARK: - Selection

    private func attemptSelection(at point: CGPoint) {
        guard let selection = resolveEligibleWindow(at: point) else {
            Log.plot.info("No eligible window under cursor at (\(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public))")
            // Stay in awaitingWindow.
            return
        }
        state = .windowSelected(selection)
        overlay.setSelectedFrame(selection.capturedFrame)
        overlay.showPulse(around: selection.capturedFrame, style: .selection)
        // Fade the pill so it doesn't visually obscure screen area
        // near the top of the display while the user drags their
        // Plot Area. The Esc reminder stays readable at low alpha.
        hint.dim()
        Log.plot.notice("Selected: '\(selection.ownerName, privacy: .public)' win \(selection.windowID, privacy: .public)")
    }

    private func attemptControlClickReselection(
        currentSelection: PlotSelection,
        at point: CGPoint
    ) {
        guard let newSelection = resolveEligibleWindow(at: point) else {
            // Invalid Control-click doesn't clear the valid target.
            state = .windowSelected(currentSelection)
            Log.plot.info("Control-click on ineligible area — retained '\(currentSelection.ownerName, privacy: .public)'")
            return
        }
        if newSelection.windowID == currentSelection.windowID {
            // Control-click on same window is a no-op.
            state = .windowSelected(currentSelection)
            return
        }
        state = .windowSelected(newSelection)
        overlay.setSelectedFrame(newSelection.capturedFrame)
        overlay.showPulse(around: newSelection.capturedFrame, style: .selection)
        Log.plot.notice("Control-click reselect: '\(currentSelection.ownerName, privacy: .public)' → '\(newSelection.ownerName, privacy: .public)'")
    }

    private func resolveEligibleWindow(at point: CGPoint) -> PlotSelection? {
        // CrossAppWindowEnumerator returns front-to-back, filtered
        // against system junk, our own overlays, and windows too
        // small to be user-interactive. First hit wins.
        let all = CrossAppWindowEnumerator.allVisibleWindows()
        guard let vw = all.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        // Resolve AX element via frame match. Same pattern as
        // LassoCoordinator's cache warm-up: enumerate the owning
        // app's windows, match by frame ±4pt tolerance.
        guard let app = NSRunningApplication(processIdentifier: vw.ownerPID) else {
            return nil
        }
        let axWindows = AXWindowEnumerator.windows(of: app)
        // Strict match first — frame within 4pt tolerance handles
        // apps whose CGWindowList and AX frames agree exactly.
        // Fallback: after a plot the just-moved window's CGWindowList
        // bounds can lag AX by hundreds of ms — the CGWindow frame
        // reports the pre-plot position while AX reports the actual
        // current position. That mismatch previously broke reselect
        // for a window the user had already plotted. If strict match
        // fails, use the AX window whose CURRENT frame contains the
        // click point: AX is authoritative, and the user is clicking
        // at a real on-screen location.
        let element: EnumeratedWindow?
        if let strict = axWindows.first(where: { rectsApproxEqual($0.frame, vw.frame, tolerance: 4) }) {
            element = strict
        } else if let containing = axWindows.first(where: { $0.frame.contains(point) }) {
            element = containing
            Log.plot.info("Hit '\(vw.ownerName, privacy: .public)' win \(vw.windowID, privacy: .public) — CGWindow frame stale, matched by AX-contains-point")
        } else {
            element = nil
        }
        guard let resolved = element else {
            Log.plot.info("Hit '\(vw.ownerName, privacy: .public)' win \(vw.windowID, privacy: .public) but no AX element match (0/\(axWindows.count, privacy: .public) candidates) — ineligible")
            return nil
        }
        // Use the AX-fresh frame for the selection outline so the
        // pulse renders around where the window actually IS, not
        // where CGWindow's stale cache says it was.
        return PlotSelection(
            windowID: vw.windowID,
            ownerPID: vw.ownerPID,
            ownerName: vw.ownerName,
            bundleID: app.bundleIdentifier,
            capturedFrame: resolved.frame,
            axElement: resolved.axElement
        )
    }

    // MARK: - Drawing

    private func updateDrawingPreview(currentPoint: CGPoint) {
        guard case .drawingPlot(let selection, let dragStart, let screen, let previousSnap) = state else {
            return
        }
        let raw = PlotGeometry.normalize(from: dragStart, to: currentPoint)
        let (finalRect, snap) = PlotGeometry.computePlotArea(
            rawRect: raw,
            visibleFrame: screen.visibleFrame,
            previous: previousSnap
        )
        state = .drawingPlot(
            selection: selection,
            dragStart: dragStart,
            targetScreen: screen,
            snap: snap
        )
        let valid = PlotGeometry.isValidPlotArea(finalRect)
        overlay.setPreview(finalRect, snap: snap, isValid: valid)
    }

    // MARK: - Commit

    private func commitDrawnPlot(
        selection: PlotSelection,
        dragStart: CGPoint,
        mouseUp: CGPoint,
        screen: NSScreen
    ) {
        let raw = PlotGeometry.normalize(from: dragStart, to: mouseUp)
        let (finalRect, snap) = PlotGeometry.computePlotArea(
            rawRect: raw,
            visibleFrame: screen.visibleFrame,
            // Use current snap-state so the frozen preview reflects
            // exactly what the user sees when they released.
            previous: currentSnapForCommit()
        )

        guard PlotGeometry.isValidPlotArea(finalRect) else {
            // Invalid Plot Area: no mutation, no landing pulse.
            // Return to windowSelected so the user can try again.
            Log.plot.notice("Invalid Plot Area \(Int(finalRect.width), privacy: .public)×\(Int(finalRect.height), privacy: .public) — no move")
            overlay.setPreview(nil, snap: .none, isValid: true)
            state = .windowSelected(selection)
            return
        }

        state = .committing
        overlay.setPreview(finalRect, snap: snap, isValid: true)

        // Preflight guards — checked ONCE here, before either transport
        // path runs. Both transports depend on all of these; a per-
        // path duplication would risk drift.
        guard isTrusted() else {
            Log.plot.error("Commit aborted — AX permission lost")
            overlay.setPreview(nil, snap: .none, isValid: true)
            overlay.setSelectedFrame(nil)
            returnToAwaitingWindow()
            return
        }
        guard NSScreen.screens.contains(screen) else {
            Log.plot.notice("Commit aborted — target display disappeared")
            overlay.setPreview(nil, snap: .none, isValid: true)
            overlay.setSelectedFrame(nil)
            returnToAwaitingWindow()
            return
        }
        guard AXWindowEnumerator.currentFrame(of: selection.axElement) != nil else {
            Log.plot.notice("Commit aborted — selected window disappeared")
            overlay.setPreview(nil, snap: .none, isValid: true)
            overlay.setSelectedFrame(nil)
            returnToAwaitingWindow()
            return
        }
        var positionSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(
            selection.axElement,
            kAXPositionAttribute as CFString,
            &positionSettable
        )
        guard positionSettable.boolValue else {
            Log.plot.notice("Position not settable for '\(selection.ownerName, privacy: .public)' — can't plot")
            overlay.setPreview(nil, snap: .none, isValid: true)
            overlay.setSelectedFrame(nil)
            returnToAwaitingWindow()
            return
        }

        // Transport decision. Chromium-family targets go through the
        // AppleScript `bounds` path when the flag is on (persistent
        // where AX size writes revert). Everything else goes through
        // the existing AX path unchanged.
        let canUseNative = useBrowserNativeBoundsForPlot
            && (selection.bundleID.map { BrowserScripting.supportsNativeWindowBounds(bundleID: $0) } ?? false)

        if canUseNative, let bundleID = selection.bundleID {
            // Async native path. Task capture pins the current
            // generation so a mid-flight Escape can bail the Task
            // safely without touching windows.
            let capturedGeneration = generation
            Task { [weak self] in
                await self?.commitViaNative(
                    selection: selection,
                    bundleID: bundleID,
                    finalRect: finalRect,
                    snap: snap,
                    screen: screen,
                    generation: capturedGeneration
                )
            }
        } else {
            commitViaAX(
                selection: selection,
                finalRect: finalRect,
                snap: snap,
                screen: screen,
                transport: .ax
            )
        }
    }

    /// Which mutation path a completed Plot commit used. Fed into
    /// `finishCommit` for a truthful transport log line so the user's
    /// / handoff developer's Console output reflects reality instead
    /// of a transient AX readback.
    private enum PlotTransport {
        /// Standard AX size-position-size dance (non-Chromium, or
        /// Chromium with the native flag off).
        case ax
        /// Chromium AppleScript `set bounds` succeeded.
        case browserNative
        /// Chromium native transport was attempted and failed; the
        /// AX path ran as fallback. Carries the failure reason for
        /// diagnostics.
        case axFallback(nativeFailure: String)
    }

    /// The pre-existing AX Plot commit body. Invoked directly for
    /// non-Chromium windows and used as the sole fallback when the
    /// native transport reports a pre-write failure. Nothing here
    /// changed except:
    ///   - it now accepts a `transport` argument so `finishCommit`
    ///     can log truthfully
    ///   - the preflight guards that used to live in-line moved up
    ///     into `commitDrawnPlot` so BOTH paths share them
    private func commitViaAX(
        selection: PlotSelection,
        finalRect: CGRect,
        snap: PlotSnapIntent,
        screen: NSScreen,
        transport: PlotTransport
    ) {
        // Step 1a: request the intended frame. Always call setFrame
        // unconditionally — setFrame internally checks isSizeSettable
        // and falls back to position-only when the size attribute
        // isn't writable. Matching CascadeOrchestrator.applyBatch
        // fixes an earlier bug where Chrome's AX proxy transiently
        // reported size as non-settable and we skipped the size dance.
        _ = WindowMutator.setFrame(finalRect, of: selection.axElement)

        // Step 1b: read back what the app currently reports.
        let firstReadbackAX = AXWindowEnumerator.currentFrame(of: selection.axElement)
        let firstReadbackCocoa = firstReadbackAX.map { CoordinateSpace.cocoaRect(fromAX: $0) }

        // Step 1c: if the app returned a size that differs meaningfully
        // from what we asked for, apply setFrame ONE more time. Chrome
        // in particular commits our size briefly (visible in the
        // WindowMutator "App refused resize — got …" log line) and then
        // its own layout code restores its persisted preferred size a
        // few ms later. A second setFrame call after the first readback
        // overwrites that revert before it can settle. If the first
        // write already stuck (Terminal / Finder / most apps), this
        // second call is a cheap no-op — the sizes already match.
        if let first = firstReadbackCocoa {
            let widthDelta  = abs(first.width  - finalRect.width)
            let heightDelta = abs(first.height - finalRect.height)
            if widthDelta > 4 || heightDelta > 4 {
                _ = WindowMutator.setFrame(finalRect, of: selection.axElement)
            }
        }

        // Step 2: read back the post-retry frame the app actually
        // accepted. This is authoritative for the correction pass.
        guard let actualAX = AXWindowEnumerator.currentFrame(of: selection.axElement) else {
            Log.plot.notice("Post-commit readback failed for '\(selection.ownerName, privacy: .public)'")
            finishCommit(selection: selection, actualFrame: finalRect, transport: transport)
            return
        }
        let actualCocoa = CoordinateSpace.cocoaRect(fromAX: actualAX)

        // Step 3: if the actual size STILL differs from requested (app
        // has an enforced constraint we can't override — Get Info,
        // Xcode's minimum-column width, etc.), apply ONE corrective
        // position write that preserves snap intent so the window at
        // least ends up anchored to the correct edge.
        let sizeDelta = abs(actualCocoa.width  - finalRect.width) > 2
                     || abs(actualCocoa.height - finalRect.height) > 2
        if sizeDelta {
            let corrected = PlotGeometry.correctForConstraints(
                actualSize: actualCocoa.size,
                requested: finalRect,
                intent: snap,
                visibleFrame: screen.visibleFrame
            )
            if abs(corrected.minX - actualCocoa.minX) > 1
                || abs(corrected.minY - actualCocoa.minY) > 1 {
                _ = WindowMutator.setPosition(of: selection.axElement, cocoaFrame: corrected)
            }
        }

        // Step 4: read final actual frame for landing pulse.
        let finalActual: CGRect
        if let axFrame = AXWindowEnumerator.currentFrame(of: selection.axElement) {
            finalActual = CoordinateSpace.cocoaRect(fromAX: axFrame)
        } else {
            finalActual = finalRect
        }

        // Step 5: raise plotted window (single AX raise action). No
        // multi-window walk, no cascade z-order enforcement.
        AXUIElementPerformAction(selection.axElement, kAXRaiseAction as CFString)

        finishCommit(selection: selection, actualFrame: finalActual, transport: transport)
    }

    /// Chromium native-bounds commit path. Async: dispatches the
    /// AppleScript on a background thread via
    /// `BrowserScripting.setBrowserWindowBoundsNearFrame`, waits a
    /// short settling interval, reads the AX-settled frame, and
    /// (per spec) may retry ONCE more via fresh native resolve if
    /// the settled frame diverges. Never layers repeated AX size
    /// writes after native success — that produced the visible
    /// bouncing an earlier iteration removed.
    ///
    /// On any pre-write native failure (unsupported / permission /
    /// browser not running / no or ambiguous match / timeout / script
    /// error / target gone), falls back to the existing AX path
    /// exactly once — matching the spec's "one AX fallback" contract.
    /// After native success but settled-mismatch, ONE additional
    /// fresh native attempt runs; if that also fails to persist,
    /// commit completes at the observed frame with a
    /// `settled-mismatch` log — no further mutation.
    ///
    /// Generation-guarded — a mid-flight Escape or new Plot cycle
    /// bumps `generation`; each await checkpoint verifies the guard
    /// and bails cleanly (no window mutation, no landing pulse, no
    /// state churn).
    private func commitViaNative(
        selection: PlotSelection,
        bundleID: String,
        finalRect: CGRect,
        snap: PlotSnapIntent,
        screen: NSScreen,
        generation capturedGeneration: UInt64
    ) async {
        // Fresh AX current frame — used to match the browser window
        // in the native enumeration. Stale frames from `capturedFrame`
        // would misidentify a window the user has just repositioned.
        guard generation == capturedGeneration else { return }
        guard let currentAX = AXWindowEnumerator.currentFrame(of: selection.axElement) else {
            Log.plot.notice("Native commit aborted — selected window disappeared before request")
            finishAborted(selection: selection)
            return
        }
        let targetAX = CoordinateSpace.axRect(fromCocoa: finalRect)

        // Fire native bounds. This awaits an off-main AppleScript.
        let attemptStart = CFAbsoluteTimeGetCurrent()
        let result = await BrowserScripting.setBrowserWindowBoundsNearFrame(
            bundleID: bundleID,
            currentBoundsAX: currentAX,
            targetBoundsAX: targetAX
        )
        // Re-check generation after every await checkpoint. If Plot
        // ended mid-flight, drop the result without mutation.
        guard generation == capturedGeneration else {
            Log.plot.info("Native commit result dropped — generation advanced")
            return
        }

        switch result {
        case .success(let elapsed):
            await handleNativeSuccessAndSettle(
                selection: selection,
                bundleID: bundleID,
                finalRect: finalRect,
                snap: snap,
                screen: screen,
                capturedGeneration: capturedGeneration,
                firstElapsed: elapsed,
                nativeAttempts: 1
            )
        case .unsupported, .automationDenied, .permissionUnavailable,
             .browserNotRunning, .noMatch, .ambiguousMatch, .timedOut,
             .targetDisappeared, .scriptError:
            let reason = nativeFailureReason(result)
            Log.plot.notice(
                "Plot native pre-write failure: app='\(selection.ownerName, privacy: .public)' bundle=\(bundleID, privacy: .public) reason=\(reason, privacy: .public) elapsed=\(Int((CFAbsoluteTimeGetCurrent() - attemptStart) * 1000), privacy: .public)ms — falling back to AX"
            )
            // Single AX fallback. Preserves existing constraint
            // correction; runs on main synchronously.
            commitViaAX(
                selection: selection,
                finalRect: finalRect,
                snap: snap,
                screen: screen,
                transport: .axFallback(nativeFailure: reason)
            )
        }
    }

    /// Handles the settled-verification step after a successful native
    /// bounds write. Sleeps for `plotNativeSettleDelay`, reads the AX
    /// frame, and — if size still differs materially — performs at
    /// most one additional fresh native resolve-and-set attempt.
    private func handleNativeSuccessAndSettle(
        selection: PlotSelection,
        bundleID: String,
        finalRect: CGRect,
        snap: PlotSnapIntent,
        screen: NSScreen,
        capturedGeneration: UInt64,
        firstElapsed: TimeInterval,
        nativeAttempts: Int
    ) async {
        // Settling interval — off main during the sleep.
        try? await Task.sleep(nanoseconds: UInt64(plotNativeSettleDelay * 1_000_000_000))
        guard generation == capturedGeneration else {
            Log.plot.info("Native settled-verify dropped — generation advanced")
            return
        }
        guard AXWindowEnumerator.currentFrame(of: selection.axElement) != nil else {
            Log.plot.notice("Native commit — selected window disappeared during settle")
            finishAborted(selection: selection)
            return
        }
        guard let settledAX = AXWindowEnumerator.currentFrame(of: selection.axElement) else {
            // Unreachable given the check just above; defensive.
            finishCommit(selection: selection, actualFrame: finalRect, transport: .browserNative)
            return
        }
        let settledCocoa = CoordinateSpace.cocoaRect(fromAX: settledAX)

        // Compare settled with requested. Position correction runs
        // ONLY when a persistent size mismatch remains AND we've
        // exhausted the one-retry budget — matches spec §"Plot native
        // success with settled mismatch".
        let widthOff  = abs(settledCocoa.width  - finalRect.width)  > 4
        let heightOff = abs(settledCocoa.height - finalRect.height) > 4
        let sizeSettled = !widthOff && !heightOff

        if sizeSettled {
            // Native placement is authoritative. No AX size follow-up.
            // Raise once via AX, then finish.
            AXUIElementPerformAction(selection.axElement, kAXRaiseAction as CFString)
            let settledAfterMs = Int(plotNativeSettleDelay * 1000)
            let firstMs = Int(firstElapsed * 1000)
            Log.plot.notice(
                "Plot commit: app='\(selection.ownerName, privacy: .public)' transport=browser-native requested=(\(Int(finalRect.minX), privacy: .public),\(Int(finalRect.minY), privacy: .public) \(Int(finalRect.width), privacy: .public)×\(Int(finalRect.height), privacy: .public)) settled=(\(Int(settledCocoa.minX), privacy: .public),\(Int(settledCocoa.minY), privacy: .public) \(Int(settledCocoa.width), privacy: .public)×\(Int(settledCocoa.height), privacy: .public)) settledAfter=\(settledAfterMs, privacy: .public)ms nativeWrite=\(firstMs, privacy: .public)ms attempts=\(nativeAttempts, privacy: .public) result=success"
            )
            finishCommit(
                selection: selection,
                actualFrame: settledCocoa,
                transport: .browserNative
            )
            return
        }

        // Settled mismatch. Allow ONE additional fresh native attempt.
        // The retry re-enumerates and re-matches — never reuses the
        // earlier positional index.
        if nativeAttempts < 2 {
            let refreshedAX = AXWindowEnumerator.currentFrame(of: selection.axElement)
            let refreshedCurrent = refreshedAX ?? settledAX
            let targetAX = CoordinateSpace.axRect(fromCocoa: finalRect)
            let retryStart = CFAbsoluteTimeGetCurrent()
            let retry = await BrowserScripting.setBrowserWindowBoundsNearFrame(
                bundleID: bundleID,
                currentBoundsAX: refreshedCurrent,
                targetBoundsAX: targetAX
            )
            guard generation == capturedGeneration else { return }
            switch retry {
            case .success(let retryElapsed):
                await handleNativeSuccessAndSettle(
                    selection: selection,
                    bundleID: bundleID,
                    finalRect: finalRect,
                    snap: snap,
                    screen: screen,
                    capturedGeneration: capturedGeneration,
                    firstElapsed: retryElapsed,
                    nativeAttempts: nativeAttempts + 1
                )
                return
            case .unsupported, .automationDenied, .permissionUnavailable,
                 .browserNotRunning, .noMatch, .ambiguousMatch, .timedOut,
                 .targetDisappeared, .scriptError:
                // Retry pre-write failure. Fall through to
                // settled-mismatch handling; do NOT chain another
                // fallback loop (spec: at most one AX fallback for
                // pre-write failure — that budget was already
                // available for the first attempt and was not spent).
                let reason = nativeFailureReason(retry)
                Log.plot.notice(
                    "Plot native retry failed after settled-mismatch: reason=\(reason, privacy: .public) elapsed=\(Int((CFAbsoluteTimeGetCurrent() - retryStart) * 1000), privacy: .public)ms — accepting first settled frame"
                )
            }
        }

        // Persistent settled-mismatch after retry budget exhausted.
        // Read final actual, position-correct if snap intent still
        // benefits from it, raise, finish with settled-mismatch log.
        let finalActualCocoa: CGRect
        if let axFrame = AXWindowEnumerator.currentFrame(of: selection.axElement) {
            finalActualCocoa = CoordinateSpace.cocoaRect(fromAX: axFrame)
        } else {
            finalActualCocoa = settledCocoa
        }
        // Position correction is safe here — we've already accepted
        // that the size won't match; anchoring to snap intent keeps
        // the window flush against the edge the user drew to.
        let sizeStillOff = abs(finalActualCocoa.width  - finalRect.width)  > 2
                        || abs(finalActualCocoa.height - finalRect.height) > 2
        if sizeStillOff {
            let corrected = PlotGeometry.correctForConstraints(
                actualSize: finalActualCocoa.size,
                requested: finalRect,
                intent: snap,
                visibleFrame: screen.visibleFrame
            )
            if abs(corrected.minX - finalActualCocoa.minX) > 1
                || abs(corrected.minY - finalActualCocoa.minY) > 1 {
                _ = WindowMutator.setPosition(of: selection.axElement, cocoaFrame: corrected)
            }
        }
        let mismatchFinal: CGRect
        if let axFrame = AXWindowEnumerator.currentFrame(of: selection.axElement) {
            mismatchFinal = CoordinateSpace.cocoaRect(fromAX: axFrame)
        } else {
            mismatchFinal = finalActualCocoa
        }
        AXUIElementPerformAction(selection.axElement, kAXRaiseAction as CFString)
        Log.plot.notice(
            "Plot commit: app='\(selection.ownerName, privacy: .public)' transport=browser-native requested=(\(Int(finalRect.minX), privacy: .public),\(Int(finalRect.minY), privacy: .public) \(Int(finalRect.width), privacy: .public)×\(Int(finalRect.height), privacy: .public)) settled=(\(Int(mismatchFinal.minX), privacy: .public),\(Int(mismatchFinal.minY), privacy: .public) \(Int(mismatchFinal.width), privacy: .public)×\(Int(mismatchFinal.height), privacy: .public)) attempts=\(nativeAttempts, privacy: .public) result=settled-mismatch"
        )
        finishCommit(
            selection: selection,
            actualFrame: mismatchFinal,
            transport: .browserNative
        )
    }

    /// Called when the native commit path can't proceed (window
    /// disappeared mid-flight). Clears overlay state and returns to
    /// awaitingWindow — same cleanup as the sync abort paths above,
    /// factored out for the async site.
    private func finishAborted(selection: PlotSelection) {
        overlay.setPreview(nil, snap: .none, isValid: true)
        overlay.setSelectedFrame(nil)
        returnToAwaitingWindow()
    }

    private func nativeFailureReason(_ result: BrowserScripting.BrowserBoundsMoveResult) -> String {
        switch result {
        case .success: return "success"
        case .unsupported: return "unsupported"
        case .automationDenied: return "automation-denied"
        case .permissionUnavailable: return "permission-unavailable"
        case .browserNotRunning: return "browser-not-running"
        case .noMatch: return "no-match"
        case .ambiguousMatch: return "ambiguous-match"
        case .timedOut: return "timed-out"
        case .targetDisappeared: return "target-disappeared"
        case .scriptError(let msg): return "script-error(\(msg))"
        }
    }

    private func currentSnapForCommit() -> PlotSnapState {
        if case .drawingPlot(_, _, _, let snap) = state {
            return snap
        }
        return .none
    }

    private func finishCommit(
        selection: PlotSelection,
        actualFrame: CGRect,
        transport: PlotTransport
    ) {
        lastCommittedFrame = actualFrame
        // Remove selection outline + preview; landing pulse plays
        // around actual frame.
        overlay.setSelectedFrame(nil)
        overlay.setPreview(nil, snap: .none, isValid: true)
        overlay.showPulse(around: actualFrame, style: .landing)
        // Transport-labeled completion log. The `browser-native`
        // outcome details (settled/attempts/settledAfter/mismatch)
        // are logged at the site that observed them; this line is
        // the concise single-line "here's what happened" summary
        // that shows up for EVERY commit path.
        let transportLabel: String
        switch transport {
        case .ax:                              transportLabel = "ax"
        case .browserNative:                   transportLabel = "browser-native"
        case .axFallback(let reason):          transportLabel = "ax-fallback(nativeFailure=\(reason))"
        }
        Log.plot.notice("Plot complete: '\(selection.ownerName, privacy: .public)' transport=\(transportLabel, privacy: .public) → (\(Int(actualFrame.minX), privacy: .public),\(Int(actualFrame.minY), privacy: .public)) \(Int(actualFrame.width), privacy: .public)×\(Int(actualFrame.height), privacy: .public)")
        returnToAwaitingWindow()
    }

    /// Centralized "back to awaitingWindow" transition. Restores the
    /// pill to full opacity so the mode reminder is clearly visible
    /// again while the user picks the next target. Used by every
    /// return-to-awaiting path: successful commit, all commit-failure
    /// bailouts, display-change target-loss, target-disappeared.
    private func returnToAwaitingWindow() {
        state = .awaitingWindow
        hint.undim()
    }

    // MARK: - Display change

    private func wireScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        // Cancel any in-flight drag or pending gesture — the display
        // config that anchored them is now stale.
        switch state {
        case .inactive, .awaitingWindow:
            return
        case .windowSelected(let sel):
            // Selected window may have moved with its display; keep
            // the selection if we can still find its AX element.
            if AXWindowEnumerator.currentFrame(of: sel.axElement) == nil {
                overlay.setSelectedFrame(nil)
                returnToAwaitingWindow()
            }
        case .pendingGesture(let sel, _, _), .drawingPlot(let sel, _, _, _):
            Log.plot.notice("Screen config changed mid-gesture — cancelling drag")
            overlay.setPreview(nil, snap: .none, isValid: true)
            if AXWindowEnumerator.currentFrame(of: sel.axElement) != nil {
                // Retain the selection and its dimmed pill — the user
                // simply lost the drag they were mid-way through.
                state = .windowSelected(sel)
            } else {
                overlay.setSelectedFrame(nil)
                returnToAwaitingWindow()
            }
        case .committing:
            // Commit path returns to awaitingWindow on its own; no
            // action needed here.
            return
        }
    }

    // MARK: - Helpers

    private func rectsApproxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width  - b.width)  < tolerance
            && abs(a.height - b.height) < tolerance
    }
}

// MARK: - Diagnostic helpers

private extension NSScreen {
    /// Short human-readable label for a screen — used in Plot log
    /// lines to identify which display a target lock applies to.
    var plotShortDescription: String {
        let f = frame
        return "\(localizedName) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))]"
    }
}
