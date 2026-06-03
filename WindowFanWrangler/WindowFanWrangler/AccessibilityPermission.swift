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

    /// Adaptive polling intervals.
    ///
    /// During onboarding (state == NOT trusted), we want the toggle in
    /// System Settings to be reflected within ~1s so the user gets a
    /// snappy "permission detected → onboarding dismisses" experience.
    ///
    /// Once permission has been granted and is the steady state, the
    /// app shouldn't be hitting an OS-level entitlement check every
    /// second forever. We slow the cadence down to keep CPU/battery
    /// cost negligible while still picking up a revocation within a
    /// few seconds (rare event, doesn't need sub-second latency).
    private static let pollIntervalNotTrusted: TimeInterval = 1.0
    private static let pollIntervalTrusted:    TimeInterval = 3.0

    private var pollTimer: Timer?
    private var lastKnownState: Bool = false
    private var changeCallback: ((Bool) -> Void)?

    /// Starts checking permission state. Calls `callback` immediately
    /// with the current state, then again only when it changes. The
    /// poll cadence is fast (1s) while not trusted and slower (3s)
    /// once trusted — see `pollInterval*` constants.
    /// Safe to call again; replaces any existing poll.
    func startPolling(onChange callback: @escaping (Bool) -> Void) {
        stopPolling()
        changeCallback = callback
        lastKnownState = Self.isTrusted()
        callback(lastKnownState)
        scheduleTimer(interval: intervalFor(lastKnownState))
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        changeCallback = nil
    }

    // MARK: - Internal

    private func intervalFor(_ trusted: Bool) -> TimeInterval {
        trusted ? Self.pollIntervalTrusted : Self.pollIntervalNotTrusted
    }

    private func scheduleTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so MainActor isolation is fine.
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.isTrusted()
                guard current != self.lastKnownState else { return }
                self.lastKnownState = current
                self.changeCallback?(current)
                // Cadence changes with state: speed up when revoked,
                // slow down when granted.
                let newInterval = self.intervalFor(current)
                if abs(newInterval - interval) > 0.01 {
                    self.scheduleTimer(interval: newInterval)
                }
            }
        }
    }
}
