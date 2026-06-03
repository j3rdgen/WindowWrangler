//
//  GlobalShortcuts.swift
//  Window Wrangler
//
//  Minimal global-keyboard-shortcut registry. Listens for keyDown
//  events anywhere in the system via NSEvent's global monitor (which
//  requires the Accessibility permission we already hold).
//
//  Per CLAUDE.md "Global event capture isolated": this module owns the
//  monitor handle and dispatches matched events to registered actions.
//  It does NOT own business logic — actions are closures provided by
//  the caller.
//
//  The global monitor observes events but does not consume them. For
//  the three-modifier shortcuts we're wiring (⌃⌥⇧+arrow / return),
//  there is no app conflict to worry about. If conflicts arise later
//  we can migrate to CGEventTap, which can consume.
//

import AppKit
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

    private var monitor: Any?
    private var bindings: [Binding] = []

    /// Adds a binding. Bindings can be registered before or after
    /// `start()` — they take effect once the monitor is running.
    func register(_ binding: Binding) {
        bindings.append(binding)
    }

    /// Begins listening for global keyDown events. Safe to call once.
    /// Idempotent — calling again replaces any existing monitor.
    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }
    }

    /// Removes the global event monitor.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // MARK: - Private

    private func handleKeyDown(_ event: NSEvent) {
        // Only consider the four modifier keys for matching. Ignore
        // device-specific flags (.numericPad, .function, capsLock, etc.)
        // so a user with Caps Lock on doesn't break shortcuts.
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let eventMods = event.modifierFlags.intersection(relevant)

        for binding in bindings {
            if event.keyCode == binding.keyCode && eventMods == binding.modifiers {
                Log.shortcuts.notice("Shortcut fired: \(binding.label, privacy: .public)")
                binding.action()
                return
            }
        }
    }
}

// MARK: - Virtual key codes

/// Common virtual key codes (from Carbon's `Events.h` / `kVK_*` constants).
/// Wrapped here so callers don't need to import Carbon.
enum KeyCode {
    static let leftArrow:  UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow:  UInt16 = 0x7D
    static let upArrow:    UInt16 = 0x7E
    static let `return`:   UInt16 = 0x24
    static let escape:     UInt16 = 0x35
    static let space:      UInt16 = 0x31
    static let c:          UInt16 = 0x08  // kVK_ANSI_C
    static let comma:      UInt16 = 0x2B  // kVK_ANSI_Comma
    static let period:     UInt16 = 0x2F  // kVK_ANSI_Period
}
