//
//  GlobalEventMonitor.swift
//  Window Wrangler
//
//  Observes global mouse + escape events for the lasso flow.
//
//  Mouse events go through a CGEventTap so we can CONSUME the
//  left-mouse-down/dragged/up events while lasso mode is active.
//  Without consumption, Finder's native desktop rubber-band would
//  fire in parallel and select desktop icons/folders/screenshots
//  underneath our lasso — the "dual-input" problem CLAUDE.md
//  anticipated by reserving CGEventTap for exactly this scenario.
//
//  Escape stays on the NSEvent global monitor — we don't need to
//  consume escape, and the simpler API is fine for a key-only watcher.
//
//  Per CLAUDE.md "Global event capture isolated": this module owns the
//  tap + monitor handles and emits high-level callbacks. It knows
//  nothing about selection state or overlay rendering.
//

import AppKit
import CoreGraphics
import os

@MainActor
final class GlobalEventMonitor {

    // MARK: - Public state

    /// Toggled by the caller (LassoCoordinator) when the user presses
    /// the lasso mode shortcut. While true, mouse drags are forwarded
    /// via the drag callbacks AND consumed by our event tap so they
    /// don't reach other apps (Finder's desktop selection in particular).
    /// While false, mouse events pass through untouched.
    var isLassoModeActive: Bool = false

    // MARK: - Callbacks

    /// Mouse-down location in Cocoa global coords. Only fires while
    /// `isLassoModeActive` is true.
    var onLassoDragBegan: ((CGPoint) -> Void)?

    /// Updated mouse location during drag, in Cocoa global coords.
    var onLassoDragUpdated: ((CGPoint) -> Void)?

    /// Drag completed at this location. Fires if drag was in progress
    /// (started while lasso mode was active), regardless of whether
    /// lasso mode is still active at mouse-up.
    var onLassoDragEnded: ((CGPoint) -> Void)?

    /// User pressed Escape — caller decides what to do (typically clear
    /// the selection and turn off lasso mode).
    var onEscapePressed: (() -> Void)?

    // MARK: - State

    /// True once a mouseDown has fired in lasso mode and we're waiting
    /// for the matching mouseUp. Independent of `isLassoModeActive` so
    /// a drag completes cleanly even if mode is toggled off mid-drag.
    private var dragInProgress = false

    // MARK: - Monitor handles

    /// Escape detection — passive NSEvent observer (no consumption needed).
    /// `keyMonitor` fires for events destined for OTHER apps; local
    /// monitor fires for events destined for our own app. Both feed
    /// the same handler so escape works whether the user is focused
    /// on us (e.g. right after our NSAlert dismisses) or on any
    /// other app (the normal lasso case).
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    /// CGEventTap that intercepts left-mouse-down/dragged/up. Active
    /// (`.defaultTap`) so the callback can return nil to drop events.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Lifecycle

    /// Begins observing global events. Idempotent.
    func start() {
        stop()

        // Escape detection — NSEvent global monitor (passive observer)
        // is fine here. We never want to consume escape.
        //
        // Global monitor fires only when our app is NOT active
        // (which is the normal lasso case — user is interacting
        // with Finder/Chrome/whatever). Local monitor fires when
        // our app IS active — after an NSAlert dismisses, our app
        // holds focus briefly, and without the local monitor an
        // escape press here would produce macOS's "unhandled key"
        // pluck sound and leave lasso mode stuck on. Both feed the
        // same handler; the local monitor returns the event
        // unchanged so anything with a legitimate escape handler
        // (a text field, an alert) still receives it too.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleKey(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.handleKey(event)
            }
            return event
        }

        // Mouse: CGEventTap so we can consume events while lasso mode
        // is active.
        setupMouseEventTap()

        Log.lasso.notice(
            "GlobalEventMonitor: started (CGEventTap mouse=\(self.eventTap != nil ? "ok" : "FAILED", privacy: .public), NSEvent escape)"
        )
    }

    /// Enables/disables the CGEventTap. Safe before `start()`
    /// (no-op if the tap isn't created yet).
    func setTapActive(_ active: Bool) {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: active)
        if !active {
            // Reset partial drag state so a toggle-off mid-lasso
            // doesn't leave dragInProgress stuck true for the next
            // enable.
            dragInProgress = false
        }
        Log.lasso.info(
            "CGEventTap \(active ? "enabled" : "disabled", privacy: .public)"
        )
    }

    func stop() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        localKeyMonitor = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        dragInProgress = false
        isLassoModeActive = false
    }

    // MARK: - Event tap setup

    private func setupMouseEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,        // active: can consume events
            eventsOfInterest: mask,
            callback: GlobalEventMonitor.cgEventTapCallback,
            userInfo: selfPtr
        ) else {
            Log.lasso.error(
                "CGEventTap creation FAILED — lasso mouse won't fire. Check Accessibility permission."
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // Created disabled; enabled only while lasso mode is on (see
        // `setTapActive`). Keeps left-mouse interception out of the
        // system-wide event flow when the user isn't lassoing.
        CGEvent.tapEnable(tap: tap, enable: false)

        eventTap = tap
        runLoopSource = source
    }

    /// C-style callback. Bridges into our @MainActor instance method
    /// via the `userInfo` pointer we passed at tap creation.
    ///
    /// IMPORTANT: this callback runs on the main run loop and macOS
    /// will disable the tap if it doesn't return within ~75ms. Any work
    /// chained off the drag callbacks (overlay redraw, hit-test, menu
    /// rebuild) must stay well under that budget. In particular: do
    /// NOT add expensive NSLog formatting, heavy CG queries, or
    /// dispatch-sync calls here — they can blow the timeout under load
    /// and silently disable mouse handling until macOS re-enables us
    /// via `.tapDisabledByTimeout` (handled below).
    private static let cgEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<GlobalEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            monitor.handleMouseEvent(type: type, event: event)
        }
    }

    // MARK: - Event handlers

    /// Returns nil to CONSUME the event (Finder & other apps won't see
    /// it), or `Unmanaged.passUnretained(event)` to pass it through.
    private func handleMouseEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS will disable the tap if our callback takes too long
        // (~75ms timeout) or if the user explicitly resets input. Re-
        // enable on these special events so the lasso keeps working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let location = locationInCocoaCoords(event)

        // Menu bar clicks: pass through so the user can still open
        // menu-bar apps (ours + system utilities) during lasso.
        if let screen = NSScreen.screens.first, location.y > screen.visibleFrame.maxY {
            return Unmanaged.passUnretained(event)
        }

        // Clicks on our own interactive windows (name pill, release
        // menu, NSAlerts): pass through. Transparent overlays are
        // filtered out via `ignoresMouseEvents`.
        for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents {
            if window.frame.contains(location) {
                return Unmanaged.passUnretained(event)
            }
        }

        switch type {
        case .leftMouseDown:
            if isLassoModeActive {
                dragInProgress = true
                onLassoDragBegan?(location)
                return nil   // consume
            }
        case .leftMouseDragged:
            if dragInProgress {
                onLassoDragUpdated?(location)
                return nil   // consume
            }
        case .leftMouseUp:
            if dragInProgress {
                dragInProgress = false
                onLassoDragEnded?(location)
                return nil   // consume
            }
        default:
            break
        }

        // Not lasso-related (or lasso mode is off) — let the event
        // propagate normally so the user's apps respond as usual.
        return Unmanaged.passUnretained(event)
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            onEscapePressed?()
        }
    }

    /// Cancels any in-flight drag without firing the drag-ended callback.
    /// Called by LassoCoordinator when Escape is pressed mid-drag — the
    /// matching mouseUp will still be observed (and consumed) by the
    /// tap, but it won't trigger a stale `onLassoDragEnded` and won't
    /// be silently eaten with no record.
    func cancelDrag() {
        dragInProgress = false
    }

    // MARK: - Helpers

    /// Converts the CGEvent's cursor location (AX-style top-left global)
    /// into a Cocoa global point (bottom-left origin, primary display).
    private func locationInCocoaCoords(_ event: CGEvent) -> CGPoint {
        let ax = event.location
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: ax.x, y: primaryHeight - ax.y)
    }
}
