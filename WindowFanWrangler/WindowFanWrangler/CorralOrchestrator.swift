//
//  CorralOrchestrator.swift
//  Window Wrangler
//
//  Coordinates the Corral save flow (M8.2) — the module the shortcut
//  handler and menu item both call into when the user says "save my
//  current selection as a Corral."
//
//  The save happens in stages:
//    1. Preflight — is AX granted, is a selection present, is the
//       store at cap? Any failure surfaces as an NSAlert and the
//       flow ends without touching the store.
//    2. Name entry — present the CorralNamePill; wait for the user
//       to type a name and hit Return (or Escape to cancel).
//    3. Snapshot — enumerate the selection, resolve each window's
//       (bundleID, appName, title, frame, z-index), and for browser
//       members, capture the tab list via BrowserScripting.
//    4. Persist — if the name matches an existing corral, show
//       "Replace 'NAME'?" and either overwrite in place or bail. If
//       it's a fresh name, hand to CorralStore.save.
//
//  Restore lives in a later sub-milestone (M8.3); this file focuses
//  on the save path only.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

@MainActor
final class CorralOrchestrator {

    // MARK: - Dependencies

    private let store: CorralStore
    private let selection: WindowSelection
    private let isTrusted: () -> Bool

    /// Pauses/resumes the lasso mouse-event consumption while any
    /// Corral flow is on-screen. Without this, lasso mode's CGEventTap
    /// swallows clicks meant for the name pill, the "Replace 'NAME'?"
    /// alert, or the "no windows selected" alert — leaving those
    /// modal surfaces permanently unresponsive if the user triggered
    /// the flow with lasso mode on (which is the default path).
    private let suspendMouseCapture: () -> Void
    private let resumeMouseCapture: () -> Void

    // MARK: - State

    /// Retains the pill while it's on-screen; released when
    /// the user submits or cancels.
    private var namePill: CorralNamePill?

    /// Retains the success toast while it fades in/out. Auto-clears
    /// itself once the toast dismisses.
    private var successToast: CorralToast?

    /// Retains the "Saving…" progress toast that appears immediately
    /// after the pill dismisses. Displaced by the success toast when
    /// the capture finishes.
    private var progressToast: CorralToast?

    /// True while any part of the save flow is on-screen (pill or an
    /// alert). Used to make suspend/resume idempotent — repeated
    /// calls during a single flow don't stack.
    private var isFlowActive: Bool = false

    init(
        store: CorralStore,
        selection: WindowSelection,
        isTrusted: @escaping () -> Bool,
        suspendMouseCapture: @escaping () -> Void,
        resumeMouseCapture: @escaping () -> Void
    ) {
        self.store = store
        self.selection = selection
        self.isTrusted = isTrusted
        self.suspendMouseCapture = suspendMouseCapture
        self.resumeMouseCapture = resumeMouseCapture
    }

    // MARK: - Public entry point

    /// Called by ⌃⌥⌘S and the "Corral (Save Window Group)" menu
    /// item. Runs preflight; if it passes, presents the name pill.
    /// Returns immediately — the actual save happens asynchronously
    /// after the user hits Return.
    func beginSave() {
        Log.corral.notice("beginSave requested")

        // Suspend lasso mouse-consumption FIRST so any preflight
        // alert we show below can actually be clicked. Every exit
        // path in this method must resume before returning.
        beginFlow()

        guard isTrusted() else {
            showAlert(
                title: "Accessibility permission required",
                message: "Grant Window Wrangler access to Accessibility in System Settings, then try again."
            )
            endFlow()
            return
        }

        guard !selection.isEmpty else {
            showAlert(
                title: "No windows selected",
                message: "Turn on Lasso Mode with ⌃⌥⌘C, drag to select windows, then press ⌃⌥⌘S to save them as a group."
            )
            endFlow()
            return
        }

        if store.isAtCap {
            showAlert(
                title: "Group limit reached",
                message: "You have \(CorralStore.maxCorrals) saved groups. Delete one before creating a new one."
            )
            endFlow()
            return
        }

        // Snapshot the ordered selection now so a stray click during
        // name entry can't mutate what we're about to save. Selection
        // itself remains as-is; we just close over this frozen copy.
        let frozenSelection = selection.ordered
        presentNamePill(frozenSelection: frozenSelection)
        // Note: endFlow() is called from the pill's onSubmit /
        // onCancel closures, not here — the flow stays active
        // until the user finishes with the pill.
    }

    /// Marks the flow as active and suspends mouse-consumption
    /// once per flow. Repeated calls within a single flow are safe
    /// no-ops thanks to the `isFlowActive` guard — even if we route
    /// through multiple alerts and callbacks.
    private func beginFlow() {
        guard !isFlowActive else { return }
        isFlowActive = true
        suspendMouseCapture()
    }

    /// Marks the flow inactive and resumes mouse-consumption. No-op
    /// if we weren't in a flow (defensive; a stray call shouldn't
    /// erroneously toggle consumption for lasso mode).
    private func endFlow() {
        guard isFlowActive else { return }
        isFlowActive = false
        resumeMouseCapture()
    }

    // MARK: - Name entry

    private func presentNamePill(frozenSelection: [VisibleWindow]) {
        let pill = CorralNamePill()
        pill.onSubmit = { [weak self] name in
            self?.namePill = nil
            self?.completeSave(name: name, frozenSelection: frozenSelection)
            self?.endFlow()
        }
        pill.onCancel = { [weak self] in
            self?.namePill = nil
            Log.corral.info("Save cancelled by user")
            self?.endFlow()
        }
        namePill = pill
        pill.present()
    }

    // MARK: - Snapshot + persist

    private func completeSave(name: String, frozenSelection: [VisibleWindow]) {
        // Check the name collision FIRST — this is just a dict lookup,
        // so the "Replace 'NAME'?" alert appears immediately. Doing
        // the slow captureMembers work up front (as we did before)
        // made the alert appear ~500ms late because window enumeration
        // + AppleScript for browser tabs ran before the alert.
        let existing = store.existingCorral(named: name)
        if let existing {
            let confirmed = confirmOverwrite(existingName: existing.name)
            guard confirmed else {
                Log.corral.info("Overwrite cancelled by user")
                return
            }
        }

        // Show "Saving…" ONLY IF the capture is slow enough to warrant
        // it. The prefetch in `LassoCoordinator.toggleLassoMode`
        // usually populates BrowserScripting's cache before the user
        // hits ⌃⌥⌘S, so the common-case capture is ~50ms of AX title
        // reads — faster than the progress toast's own fade-in.
        //
        // Strategy: schedule the progress toast to appear after 150ms.
        // If capture finishes first, cancel the timer and the toast
        // never shows — you go straight from pill-vanish to success
        // toast with no visible progress flash. If capture is slow
        // (cache miss, cold Chrome runloop), the toast appears at
        // 150ms and gets dismissed when capture completes.
        let progressWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let progress = CorralToast()
            progress.showProgress(text: "Saving '\(name)'…")
            self.progressToast = progress
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: progressWorkItem)

        DispatchQueue.main.async { [weak self] in
            self?.finishSave(
                name: name,
                frozenSelection: frozenSelection,
                existing: existing,
                progressWorkItem: progressWorkItem
            )
        }
    }

    /// Second half of completeSave — runs on the next runloop tick so
    /// the progress toast presented by `completeSave` has painted
    /// before we block main with capture + AppleScript.
    private func finishSave(
        name: String,
        frozenSelection: [VisibleWindow],
        existing: Corral?,
        progressWorkItem: DispatchWorkItem
    ) {
        Log.corral.notice(
            "Building corral '\(name, privacy: .public)' from \(frozenSelection.count, privacy: .public) window(s)"
        )
        // Time the capture explicitly so we can see how much of the
        // save's perceived delay is AX enumeration + AppleScript vs.
        // pill/alert overhead. Emitted at .notice so it shows up in
        // Console under `corral` without needing debug-level filtering.
        let captureStart = CFAbsoluteTimeGetCurrent()
        let members = captureMembers(from: frozenSelection)
        let captureMs = Int((CFAbsoluteTimeGetCurrent() - captureStart) * 1000)
        Log.corral.notice(
            "captureMembers took \(captureMs, privacy: .public)ms — \(members.count, privacy: .public) member(s)"
        )

        // Cancel the "Saving…" toast timer — if capture finished
        // before 150ms elapsed, the toast never shows and we go
        // straight to success. If it already fired, cancel is a
        // no-op and dismissNow below cleans up the visible toast.
        progressWorkItem.cancel()
        progressToast?.dismissNow()
        progressToast = nil

        guard !members.isEmpty else {
            showAlert(
                title: "Couldn't capture any windows",
                message: "The selected windows may have closed or moved before the save completed. Try again."
            )
            return
        }

        if let existing {
            let replacement = existing.withReplacedMembers(members)
            store.overwrite(id: existing.id, with: replacement)
            showSuccessToast(name: replacement.name)
            return
        }

        let corral = Corral(name: name, members: members)
        switch store.save(corral) {
        case .saved:
            showSuccessToast(name: corral.name)
        case .atCap:
            // Shouldn't happen — preflight already checked — but be
            // defensive since the store is our source of truth.
            showAlert(
                title: "Group limit reached",
                message: "You have \(CorralStore.maxCorrals) saved groups. Delete one before creating a new one."
            )
        }
    }

    // MARK: - Success toast

    /// Shows a brief centered "✓ Saved 'NAME'" toast that fades in,
    /// holds for ~1.4s, then fades out and is released. Purely
    /// visual — the corral is already persisted by this point.
    private func showSuccessToast(name: String) {
        let toast = CorralToast()
        toast.showSaved(name: name) { [weak self] in
            self?.successToast = nil
        }
        successToast = toast
    }

    // MARK: - Member capture

    /// Turns each `VisibleWindow` into a fully-populated
    /// `CorralMember`. Titles are resolved via AX (single
    /// enumeration cached per PID). Browser windows get their tab
    /// lists via `BrowserScripting`, cached per bundle-ID so a
    /// selection with three Chrome windows only pays for one
    /// AppleScript round-trip.
    private func captureMembers(from windows: [VisibleWindow]) -> [CorralMember] {
        var axCache: [pid_t: [EnumeratedWindow]] = [:]
        var browserCache: [String: [BrowserScripting.BrowserWindowSnapshot]?] = [:]
        var members: [CorralMember] = []

        for (idx, win) in windows.enumerated() {
            guard let runningApp = NSRunningApplication(processIdentifier: win.ownerPID),
                  let bundleID = runningApp.bundleIdentifier else {
                Log.corral.info(
                    "Skipping window \(win.windowID, privacy: .public) — owner PID \(win.ownerPID, privacy: .public) no longer running"
                )
                continue
            }
            let appName = runningApp.localizedName ?? win.ownerName
            let title = resolveTitle(for: win, axCache: &axCache)

            let tabs = tabsForBrowserWindow(
                bundleID: bundleID,
                cocoaFrame: win.frame,
                cache: &browserCache
            )

            members.append(
                CorralMember(
                    appBundleID: bundleID,
                    appName: appName,
                    windowTitle: title,
                    frame: win.frame,
                    zOrderIndex: idx,
                    tabs: tabs
                )
            )
        }
        return members
    }

    /// Resolves the window's title via AX. Enumerates the owning
    /// app's AX windows once per PID and matches by frame.
    private func resolveTitle(
        for window: VisibleWindow,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> String {
        let axWindows: [EnumeratedWindow]
        if let cached = axCache[window.ownerPID] {
            axWindows = cached
        } else if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            axWindows = AXWindowEnumerator.windows(of: app)
            axCache[window.ownerPID] = axWindows
        } else {
            axCache[window.ownerPID] = []
            return ""
        }
        guard let matched = axWindows.first(where: {
            Self.framesMatch($0.frame, window.frame, tolerance: 4)
        }) else {
            return ""
        }
        var titleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            matched.axElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard result == .success, let title = titleValue as? String else { return "" }
        return title
    }

    /// If the app is a supported browser, snapshots all its windows
    /// (once, cached) and returns the tab list for the window whose
    /// bounds match the given Cocoa frame. Returns nil for non-browsers
    /// and for browsers where either scripting isn't authorized or
    /// no window matches the frame.
    private func tabsForBrowserWindow(
        bundleID: String,
        cocoaFrame: CGRect,
        cache: inout [String: [BrowserScripting.BrowserWindowSnapshot]?]
    ) -> [TabInfo]? {
        guard BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { return nil }

        // Cache lookup: nil (never queried), Optional.none (queried, no data),
        // Optional.some (queried with data).
        let snapshots: [BrowserScripting.BrowserWindowSnapshot]?
        if let cached = cache[bundleID] {
            snapshots = cached
        } else {
            let queried = BrowserScripting.snapshotBrowserWindows(bundleID: bundleID)
            cache[bundleID] = queried
            snapshots = queried
        }
        guard let snapshots else { return nil }

        // AppleScript returned AX-space (top-left) bounds; our
        // selection frames are in Cocoa (bottom-left) space. Convert
        // for matching so we compare like-to-like.
        //
        // Tolerance bumped to 20pt for browsers: Chrome's AppleScript
        // rounds bounds to integers AND appears to occasionally shave
        // a few points off vs. what kAXPosition/kAXSize report (title
        // bar / traffic-light overhang, we think). 10pt was too tight;
        // 20pt is loose enough for the observed drift without
        // introducing false positives (multiple browser windows are
        // never within 20pt of each other in practice).
        let targetAX = CoordinateSpace.axRect(fromCocoa: cocoaFrame)
        guard let match = snapshots.first(where: {
            Self.framesMatch($0.boundsAX, targetAX, tolerance: 20)
        }) else {
            // Log EVERY candidate so the user can share this and we
            // can diagnose exactly which axis (x, y, w, h) is drifting
            // and by how much. Cheap since it only fires on the
            // no-match path.
            let candidates = snapshots.map {
                "(\(Int($0.boundsAX.minX)),\(Int($0.boundsAX.minY)) \(Int($0.boundsAX.width))×\(Int($0.boundsAX.height)))"
            }.joined(separator: " | ")
            Log.corral.info(
                "No browser window matched \(bundleID, privacy: .public) — target=(\(Int(targetAX.minX), privacy: .public),\(Int(targetAX.minY), privacy: .public) \(Int(targetAX.width), privacy: .public)×\(Int(targetAX.height), privacy: .public)) candidates=[\(candidates, privacy: .public)]"
            )
            return nil
        }
        return match.tabs
    }

    /// Rectangle equality with a scalar tolerance, matched against
    /// each corner. Used both for AX-title matching (tight, 4pt) and
    /// for browser-window matching (looser, 10pt — AppleScript rounds
    /// bounds to integers so exact equality is unrealistic).
    private static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        return abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width  - b.width)  < tolerance
            && abs(a.height - b.height) < tolerance
    }

    // MARK: - Alerts

    /// Modal confirmation for the "Replace 'NAME'?" flow. Runs
    /// synchronously — the user makes a decision before we proceed.
    /// Returns true for Replace, false for Cancel.
    private func confirmOverwrite(existingName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace '\(existingName)'?"
        alert.informativeText = "A group with this name already exists. Replacing it will overwrite the saved windows."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// Generic informational alert for preflight failures. Modal
    /// because the user's next action should be an acknowledgment,
    /// not a keystroke consumed by something else.
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
