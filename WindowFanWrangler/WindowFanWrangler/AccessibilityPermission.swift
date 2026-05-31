//
//  AccessibilityPermission.swift
//  Window Wrangler
//
//  Thin wrapper around macOS's Accessibility (AX) permission API.
//  Keeps AX system calls out of the rest of the app — per CLAUDE.md's
//  "AX layer separate" architecture principle.
//
//  Responsibilities:
//   - Check whether permission is currently granted (passive, no prompt)
//   - Open System Settings directly to the Accessibility pane
//   - Poll for permission changes so the app picks up the moment
//     the user toggles the switch in System Settings
//

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityPermission {

    /// True if our process is currently trusted by macOS to use the AX API.
    /// Passive check only — does NOT trigger the system-level prompt
    /// (we present our own onboarding window instead).
    static func isTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly to Privacy & Security > Accessibility.
    /// The user still has to manually toggle the switch for our app.
    static func openSystemSettings() {
        // This URL scheme is supported on macOS 13+ and jumps to the
        // exact pane we need.
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    private var pollTimer: Timer?
    private var lastKnownState: Bool = false

    /// Starts checking permission state once per second. Calls `callback`
    /// immediately with the current state, then again only when it changes.
    /// Safe to call again; replaces any existing poll.
    func startPolling(onChange callback: @escaping (Bool) -> Void) {
        stopPolling()
        lastKnownState = Self.isTrusted()
        callback(lastKnownState)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so MainActor isolation is fine.
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.isTrusted()
                if current != self.lastKnownState {
                    self.lastKnownState = current
                    callback(current)
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
