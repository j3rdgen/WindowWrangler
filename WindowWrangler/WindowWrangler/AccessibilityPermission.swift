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
    /// The user toggles Window Wrangler ON there to grant permission.
    ///
    /// Earlier iteration of this method also called
    /// AXIsProcessTrustedWithOptions(prompt: true) to refresh a stale
    /// TCC entry, but that has the side effect of showing macOS's own
    /// native permission dialog — which then duplicates the messaging
    /// from our own onboarding window. The TCC stale-entry case is a
    /// one-time development quirk; once cleaned up manually it doesn't
    /// recur, so we don't need the system prompt in the steady-state
    /// flow.
    static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    /// Adaptive polling intervals.
    ///
    /// During onboarding (state == NOT trusted), we want the toggle in
    /// System Settings to be reflected within ~500ms so the user gets
    /// a snappy "permission detected → onboarding dismisses" experience.
    /// The onboarding window's body promises automatic closure; making
    /// good on that promise means polling fast enough that the user
    /// doesn't have time to wonder whether it worked.
    ///
    /// Once permission has been granted and is the steady state, the
    /// app shouldn't be hitting an OS-level entitlement check every
    /// half-second forever. We slow the cadence down to keep CPU /
    /// battery cost negligible while still picking up a revocation
    /// within a few seconds (rare event, doesn't need sub-second
    /// latency).
    private static let pollIntervalNotTrusted: TimeInterval = 0.5
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

    /// Forces an immediate permission re-check outside the timer cycle.
    ///
    /// Use this when an external event (e.g., another app activating)
    /// suggests the user may have just toggled our permission in
    /// System Settings — checking now gives sub-100ms responsiveness
    /// instead of waiting up to `pollIntervalNotTrusted` for the next
    /// timer fire. If the state hasn't changed, no callback fires
    /// (same contract as the regular poll).
    func forceRecheck() {
        let current = Self.isTrusted()
        guard current != lastKnownState else { return }
        lastKnownState = current
        changeCallback?(current)
        // Cadence depends on the new state — reschedule the timer to
        // match (faster while not trusted, slower once trusted).
        scheduleTimer(interval: intervalFor(current))
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
