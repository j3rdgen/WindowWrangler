//
//  AutomationPermission.swift
//  Window Wrangler
//
//  Thin wrapper around macOS's Automation-permission API (used for
//  browser tab capture / restore via AppleScript). Sibling to
//  AccessibilityPermission.swift, which handles the AX side.
//
//  Two categorically-different permissions come into play here:
//   1. Accessibility — read/write other apps' windows via AX.
//      Handled by AccessibilityPermission; user grants once in
//      System Settings > Privacy & Security > Accessibility.
//   2. Automation — send Apple Events (AppleScript) to other apps.
//      Per-target, so "control Chrome" and "control Safari" are
//      separate grants. Handled here; user grants each in System
//      Settings > Privacy & Security > Automation.
//
//  The correct API for asking is `AEDeterminePermissionToAutomateTarget`,
//  a Carbon-era C function that returns a clear status and, on first
//  call for a target, surfaces the OS's own "wants to control X"
//  dialog. Running a benign AppleScript to trigger the prompt (as
//  an earlier attempt did) doesn't reliably work — some events like
//  `get name` are exempt from TCC and don't trigger it.
//

import ApplicationServices
import AppKit

@MainActor
enum AutomationPermission {

    /// Result of a permission check.
    enum Status: Equatable {
        /// User has previously granted permission (or just did in the
        /// prompt this call triggered).
        case granted
        /// User has previously denied. macOS won't re-prompt; the
        /// user must go to System Settings > Privacy > Automation to
        /// change their decision.
        case denied
        /// Target app isn't running or bundle-ID can't be resolved.
        /// AEDeterminePermissionToAutomateTarget returns errAENoUserInteraction
        /// or similar for these cases; grouped here since our caller
        /// treats them the same.
        case notAvailable
        /// Any other error from AEDeterminePermissionToAutomateTarget.
        /// Included for logging.
        case other(OSStatus)
    }

    /// Checks (and, when `askIfNeeded` is true, prompts for)
    /// permission to send Apple Events to the app with the given
    /// bundle ID. The prompt only appears on macOS's first ask — if
    /// the user has previously decided, this returns immediately
    /// with `.granted` or `.denied`.
    static func check(bundleID: String, askIfNeeded: Bool = true) -> Status {
        guard let bundleIDData = bundleID.data(using: .utf8) else {
            return .other(-50)  // paramErr
        }
        var targetDesc = AEAddressDesc()
        let createResult: OSStatus = bundleIDData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = bytes.baseAddress else { return -50 }
            return OSStatus(AECreateDesc(
                typeApplicationBundleID,
                base,
                bytes.count,
                &targetDesc
            ))
        }
        guard createResult == noErr else { return .other(createResult) }
        defer { AEDisposeDesc(&targetDesc) }

        let result = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            typeWildCard,
            typeWildCard,
            askIfNeeded
        )
        // AppleEvents error constants — using raw values because the
        // Swift bridging of some Carbon-era names has been
        // inconsistent across SDK versions.
        //   -1743  errAEEventNotPermitted        — user previously denied
        //   -1744  errAEEventWouldRequireUserConsent — decision pending
        //                                          (returned only if
        //                                          askIfNeeded=false)
        //   -1712  errAENoUserInteraction        — no user session to prompt
        //   -600   procNotFound                  — target app not running
        switch result {
        case 0:
            return .granted
        case -1743:
            return .denied
        case -1744:
            // Would prompt but we said not to. Treat as denied for
            // our caller's purposes; they'll re-check with
            // askIfNeeded=true next time.
            return .denied
        case -1712, -600:
            return .notAvailable
        default:
            return .other(result)
        }
    }

    /// Opens System Settings > Privacy & Security > Automation. Used
    /// after we detect a `.denied` status — macOS TCC won't re-prompt,
    /// so the user has to flip the switch themselves. Provides a
    /// button-target for the alert we show in that case.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
