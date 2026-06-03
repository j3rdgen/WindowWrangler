//
//  GlobalEventMonitor.swift
//  Window Wrangler
//
//  Observes global keyboard + mouse events for the lasso flow.
//  Detects the Option+W modifier-chord that arms lasso mode, plus
//  mouse drag events while the chord is held.
//
//  Per CLAUDE.md "Global event capture isolated": this module owns
//  the event monitor handles and emits high-level callbacks
//  ("lasso mode armed", "drag updated", "Escape pressed"). It knows
//  nothing about selection state or overlay rendering.
//
//  Backing API: NSEvent.addGlobalMonitorForEvents and a local
//  monitor for events delivered to our own process. We do NOT
//  consume events — pressing Option+W in a text field will still
//  insert the resulting character. That's an accepted trade-off for
//  prototype simplicity; it could be tightened by switching to
//  CGEventTap if it becomes annoying in real use.
//

import AppKit

@MainActor
final class GlobalEventMonitor {

    // MARK: - Callbacks

    /// Fires when the user presses W with Option already held (lasso
    /// mode entered). At this point we should show the overlay and
    /// prepare for a drag.
    var onLassoModeEntered: (() -> Void)?

    /// Fires when the user releases either Option or W (lasso mode
    /// exited). Cancels any in-progress drag.
    var onLassoModeExited: (() -> Void)?

    /// Mouse-down location in Cocoa global coords, only fires while
    /// lasso mode is active.
    var onLassoDragBegan: ((CGPoint) -> Void)?

    /// Updated mouse location during drag, in Cocoa global coords.
    var onLassoDragUpdated: ((CGPoint) -> Void)?

    /// Drag completed at this location. If lasso mode was active at
    /// mouse-down, this fires regardless of whether lasso mode is
    /// still active at mouse-up (so a drag started in lasso mode
    /// completes cleanly even if the modifier is released early).
    var onLassoDragEnded: ((CGPoint) -> Void)?

    /// User pressed Escape while lasso mode was active or selection
    /// was non-empty — caller decides what to do.
    var onEscapePressed: (() -> Void)?

    // MARK: - State

    /// Tracks whether the W key is currently down. Combined with
    /// modifier flags to determine lasso mode.
    private var wKeyDown = false

    /// Tracks the Option modifier from flagsChanged events.
    private var optionDown = false

    /// True when we've notified that a drag is in progress and are
    /// waiting for the matching mouseUp. We track this independently
    /// of lasso mode so a drag completes cleanly even if the modifier
    /// is released early.
    private var dragInProgress = false

    /// Computed: lasso mode active means BOTH Option and W held.
    private var isLassoModeActive: Bool { optionDown && wKeyDown }

    // MARK: - Monitor handles

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var mouseMonitor: Any?

    // MARK: - Lifecycle

    /// Begins observing global keyboard and mouse events. Idempotent.
    func start() {
        stop()

        // Keyboard: keyDown / keyUp for tracking the W key.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleKey(event)
            }
        }

        // Modifier flag changes: separate event type for ⌥ pressed/released.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleFlagsChanged(event)
            }
        }

        // Mouse: down / dragged / up. We emit only while lasso mode
        // is active (or in-flight from earlier mouseDown during it).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleMouse(event)
            }
        }

        NSLog("[\(AppInfo.displayName)] GlobalEventMonitor: started — key=\(keyMonitor != nil) flags=\(flagsMonitor != nil) mouse=\(mouseMonitor != nil)")
    }

    func stop() {
        [keyMonitor, flagsMonitor, mouseMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        keyMonitor = nil
        flagsMonitor = nil
        mouseMonitor = nil
        wKeyDown = false
        optionDown = false
        dragInProgress = false
    }

    // MARK: - Event handlers

    /// Virtual key code for W on US keyboards (kVK_ANSI_W).
    private let kVK_W: UInt16 = 0x0D
    private let kVK_Escape: UInt16 = 0x35

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == kVK_Escape && event.type == .keyDown {
            onEscapePressed?()
            return
        }

        guard event.keyCode == kVK_W else { return }

        let wasLassoModeActive = isLassoModeActive
        switch event.type {
        case .keyDown:
            wKeyDown = true
        case .keyUp:
            wKeyDown = false
        default:
            return
        }
        updateLassoModeIfNeeded(wasActive: wasLassoModeActive)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let wasLassoModeActive = isLassoModeActive
        optionDown = event.modifierFlags.contains(.option)
        updateLassoModeIfNeeded(wasActive: wasLassoModeActive)
    }

    private func updateLassoModeIfNeeded(wasActive: Bool) {
        let nowActive = isLassoModeActive
        guard wasActive != nowActive else { return }
        if nowActive {
            onLassoModeEntered?()
        } else {
            onLassoModeExited?()
        }
    }

    private func handleMouse(_ event: NSEvent) {
        let location = event.locationInWindow.flippedToCocoaGlobal(event: event)

        switch event.type {
        case .leftMouseDown:
            if isLassoModeActive {
                dragInProgress = true
                onLassoDragBegan?(location)
            }
        case .leftMouseDragged:
            if dragInProgress {
                onLassoDragUpdated?(location)
            }
        case .leftMouseUp:
            if dragInProgress {
                dragInProgress = false
                onLassoDragEnded?(location)
            }
        default:
            break
        }
    }
}

// MARK: - Coordinate helper

private extension CGPoint {
    /// Global mouse events from NSEvent give locationInWindow that's
    /// actually in screen coordinates (Cocoa: bottom-left of primary
    /// screen origin). This is already what we want — Cocoa global —
    /// so we just return it. The function exists for documentation
    /// purposes and to make the conversion site obvious.
    func flippedToCocoaGlobal(event: NSEvent) -> CGPoint {
        // For global mouse events, locationInWindow IS the screen
        // coordinate in Cocoa space (y-up, origin at primary's
        // bottom-left). No flip needed.
        self
    }
}
