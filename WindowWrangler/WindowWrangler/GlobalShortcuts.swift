//
//  GlobalShortcuts.swift
//  Window Wrangler
//
//  Global-keyboard-shortcut registry backed by a CGEventTap. The tap
//  ACTIVELY intercepts key-down events: when a registered shortcut is
//  matched, the event is CONSUMED (dropped from the delivery chain)
//  so it never reaches the focused app.
//
//  Consumption matters. Earlier implementation used
//  NSEvent.addGlobalMonitorForEvents, which is a passive observer —
//  matched events still fired the app-level delivery. Apps like Finder
//  and Zoom explicitly beep on unhandled shortcuts, so every time our
//  ⌃⌥⌘] / ⌃⌥⌘[ chord fired while Finder or Zoom was focused, they
//  received the event, didn't recognize it, and played the system
//  pluck sound. Migrating to CGEventTap eliminates that: our tap eats
//  the shortcut before it reaches any other app.
//
//  This is the same pattern GlobalEventMonitor uses for the lasso
//  mouse events — CGEventTap when consumption matters, NSEvent when
//  only observation is needed.
//
//  Per CLAUDE.md "Global event capture isolated": this module owns the
//  tap and dispatches matched events to registered actions. It does
//  NOT own business logic — actions are closures provided by the
//  caller.
//

import AppKit
import CoreGraphics
import os

@MainActor
final class GlobalShortcuts {

    /// One shortcut binding: a modifier set, a virtual key code, and
    /// the closure to invoke when that combination is detected.
    struct Binding {
        let modifiers: NSEvent.ModifierFlags
        /// Virtual key code (kVK_*). See Carbon/HIToolbox/Events.h.
        let keyCode: UInt16
        let action: () -> Void
        /// Human-readable label for diagnostic logging.
        let label: String
    }

    private var bindings: [Binding] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Adds a binding. Bindings can be registered before or after
    /// `start()` — they take effect once the tap is running.
    func register(_ binding: Binding) {
        bindings.append(binding)
    }

    /// Begins intercepting global keyDown events via a CGEventTap.
    /// Idempotent — calling again replaces any existing tap.
    func start() {
        stop()
        setupEventTap()
        Log.shortcuts.notice(
            "GlobalShortcuts: started (CGEventTap keyDown=\(self.eventTap != nil ? "ok" : "FAILED", privacy: .public))"
        )
    }

    /// Removes the global event tap.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Tap setup

    private func setupEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // active: can consume events
            eventsOfInterest: mask,
            callback: GlobalShortcuts.tapCallback,
            userInfo: selfPtr
        ) else {
            Log.shortcuts.error(
                "CGEventTap creation FAILED — shortcuts won't fire. Check Accessibility permission."
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    /// C-style tap callback. Bridges into our @MainActor instance
    /// method via the userInfo pointer set at tap creation.
    ///
    /// IMPORTANT: runs on the main runloop but macOS will disable the
    /// tap if this callback takes more than ~75ms. Keep the handler
    /// cheap — a match returns after firing the action closure; a
    /// non-match returns the event pointer unchanged with no work.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else {
            return Unmanaged.passUnretained(event)
        }
        let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            shortcuts.handleKeyEvent(type: type, event: event)
        }
    }

    /// Returns nil to CONSUME the event (matched shortcut), or the
    /// event unchanged to let it propagate to the focused app.
    private func handleKeyEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable if macOS disabled our tap (fires when we're too
        // slow or when a user input-reset happens).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Extract keyCode and modifier flags from the CGEvent.
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let cgFlags = event.flags

        // Only consider the four modifier keys for matching. Ignore
        // device-specific flags (.numericPad, .function, capsLock, etc.)
        // so a user with Caps Lock on doesn't break shortcuts.
        var eventMods = NSEvent.ModifierFlags()
        if cgFlags.contains(.maskCommand)   { eventMods.insert(.command) }
        if cgFlags.contains(.maskAlternate) { eventMods.insert(.option) }
        if cgFlags.contains(.maskControl)   { eventMods.insert(.control) }
        if cgFlags.contains(.maskShift)     { eventMods.insert(.shift) }

        for binding in bindings {
            if keyCode == binding.keyCode && eventMods == binding.modifiers {
                Log.shortcuts.notice("Shortcut fired: \(binding.label, privacy: .public)")
                binding.action()
                // Consume — the focused app never sees this event, so
                // apps that beep on unhandled shortcuts (Finder, Zoom)
                // don't beep.
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Virtual key codes

/// Common virtual key codes (from Carbon's `Events.h` / `kVK_*` constants).
/// Wrapped here so callers don't need to import Carbon.
enum KeyCode {
    static let leftArrow:    UInt16 = 0x7B
    static let rightArrow:   UInt16 = 0x7C
    static let downArrow:    UInt16 = 0x7D
    static let upArrow:      UInt16 = 0x7E
    static let `return`:     UInt16 = 0x24
    static let escape:       UInt16 = 0x35
    static let space:        UInt16 = 0x31
    static let c:            UInt16 = 0x08  // kVK_ANSI_C
    static let d:            UInt16 = 0x02  // kVK_ANSI_D
    static let r:            UInt16 = 0x0F  // kVK_ANSI_R
    static let s:            UInt16 = 0x01  // kVK_ANSI_S
    static let comma:        UInt16 = 0x2B  // kVK_ANSI_Comma
    static let period:       UInt16 = 0x2F  // kVK_ANSI_Period
    static let leftBracket:  UInt16 = 0x21  // kVK_ANSI_LeftBracket
    static let rightBracket: UInt16 = 0x1E  // kVK_ANSI_RightBracket
    static let p:            UInt16 = 0x23  // kVK_ANSI_P
}
