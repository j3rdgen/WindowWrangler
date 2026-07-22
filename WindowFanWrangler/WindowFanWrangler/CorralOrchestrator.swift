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

    /// Retains the release menu while it's on-screen.
    private var releaseMenu: CorralReleaseMenu?

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

    // MARK: - Release flow (⌃⌥⌘R)

    /// Entry point for ⌃⌥⌘R and the future "Release" menu item.
    /// Preflights AX permission, suspends lasso mouse capture so
    /// the release menu can receive clicks, then presents the menu.
    /// The menu itself handles the empty-store case by showing an
    /// empty-state message and auto-dismissing after a short read.
    func beginRelease() {
        Log.corral.notice("beginRelease requested")

        guard isTrusted() else {
            showAlert(
                title: "Accessibility permission required",
                message: "Grant Window Wrangler access to Accessibility in System Settings, then try again."
            )
            return
        }

        // Deliberately NOT calling beginFlow() here — the release menu
        // should coexist with lasso mode, per user request. The
        // event-tap's window-frame exception (in GlobalEventMonitor)
        // already routes clicks that land on our modal windows
        // (including this menu) through to Cocoa, while clicks
        // elsewhere on screen are still consumed for lasso. Result:
        // the user can browse the release menu AND lasso-select
        // windows in the background at the same time.

        let menu = CorralReleaseMenu()
        menu.onSelect = { [weak self] corral in
            self?.releaseMenu = nil
            self?.performRestore(of: corral)
        }
        menu.onDelete = { [weak self] id in
            guard let self else { return }
            self.store.delete(id: id)
            self.releaseMenu?.refresh(corrals: self.store.corrals)
        }
        menu.onDismiss = { [weak self] in
            self?.releaseMenu = nil
        }
        releaseMenu = menu
        menu.present(corrals: store.corrals)
    }

    // MARK: - Direct restore (menu bar quick-restore)

    /// Restores a corral by id without opening the release-menu pill.
    /// Used by the menu bar dropdown's "Release ▸" submenu — clicking
    /// a corral name there triggers this directly. The pill remains
    /// the path for delete / management (via ⌃⌥⌘R or the "Manage
    /// Corrals…" menu item).
    ///
    /// Silently no-ops on missing id (corral could have been deleted
    /// between menu build and click — the menu snapshot is fresh but
    /// not atomic with the click). Also runs the same accessibility
    /// preflight as `beginRelease`.
    func restoreCorral(byID id: UUID) {
        Log.corral.notice("restoreCorral(byID:) requested — \(id.uuidString, privacy: .public)")

        guard isTrusted() else {
            showAlert(
                title: "Accessibility permission required",
                message: "Grant Window Wrangler access to Accessibility in System Settings, then try again."
            )
            return
        }

        guard let corral = store.corrals.first(where: { $0.id == id }) else {
            Log.corral.notice(
                "restoreCorral(byID:) — no corral with id \(id.uuidString, privacy: .public) (likely deleted between menu build and click)"
            )
            return
        }

        performRestore(of: corral)
    }

    // MARK: - Restore

    /// Restores every window in the given Corral. Non-browser
    /// members are re-positioned via AX; browser members with saved
    /// tabs are matched against currently-open browser windows by
    /// URL-overlap (best match wins) and, when no match is found,
    /// a fresh browser window is opened with the saved tabs via
    /// AppleScript. Z-order is re-established in reverse-slot order
    /// so the anchor (`zOrderIndex == 0`) lands on top.
    ///
    /// Missing windows (member's app not running, or no matching
    /// window found for a non-browser member) are collected and
    /// surfaced in the completion toast so the user knows exactly
    /// what got restored and what didn't.
    /// Two-phase restore. Phase 1 is synchronous: launch every app
    /// that isn't running, ask every documents-based member's app to
    /// open its specific file via `NSWorkspace.open`. Phase 2 runs
    /// after a short deferred wait so those launches have time to
    /// register their windows with the AX subsystem — then does the
    /// existing find/move/z-order pass on whatever's now available.
    ///
    /// A "Restoring '<name>'…" progress toast covers the wait so it
    /// doesn't feel like nothing's happening.
    private func performRestore(of corral: Corral) {
        Log.corral.notice(
            "Restoring '\(corral.name, privacy: .public)' with \(corral.members.count, privacy: .public) member(s) — launching apps + opening docs"
        )

        let progress = CorralToast()
        progress.showProgress(text: "Restoring '\(corral.name)'…")
        progressToast = progress

        // Group members by bundle-ID so a corral with three TextEdit
        // docs launches TextEdit exactly once and opens all three
        // docs in one NSWorkspace call.
        let membersByBundle = Dictionary(grouping: corral.members, by: { $0.appBundleID })
        var needsWait = false

        for (bundleID, membersOfBundle) in membersByBundle {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                // App isn't installed. Nothing to launch. Restore will
                // report these members as missing.
                Log.corral.info(
                    "Restore prep: no installed app for \(bundleID, privacy: .public) — will report members missing"
                )
                continue
            }

            let docURLs: [URL] = membersOfBundle.compactMap { member in
                guard let path = member.documentPath, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }

            if !docURLs.isEmpty {
                // Open specific docs. NSWorkspace.open launches the
                // app if needed AND asks it to open each URL — one
                // generic API that covers every documents-based Cocoa
                // app without per-app AppleScript.
                Log.corral.info(
                    "Restore prep: opening \(docURLs.count, privacy: .public) doc(s) via \(bundleID, privacy: .public)"
                )
                NSWorkspace.shared.open(
                    docURLs,
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
                needsWait = true
            } else {
                // No documentPath recorded. Which flavour of `open`
                // we invoke depends on the app — some apps don't
                // respond to `open -b <bundle>` on a running instance
                // and need extra arguments to create a window.
                openAppForRestore(
                    bundleID: bundleID,
                    membersOfBundle: membersOfBundle
                )
                needsWait = true
            }
        }

        // Defer the actual find/move pass so the launched apps and
        // just-opened docs have time to appear in the AX enumeration.
        // 2 seconds is long enough for TextEdit/Preview to register
        // a new window; Catalyst apps (Notes, Podcasts) can take
        // longer, so we do one retry pass 2s after the first if
        // anything's still missing.
        let delay: TimeInterval = needsWait ? 2.0 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.executeRestore(of: corral, allowRetry: true)
        }
    }

    private func executeRestore(of corral: Corral, allowRetry: Bool) {
        Log.corral.notice(
            "Executing restore for '\(corral.name, privacy: .public)'"
        )

        // Sort members by zOrderIndex ascending so we walk them in
        // "front-most first" order for logging clarity. The actual
        // z-order raise below re-iterates in reverse so the frontmost
        // ends up on top.
        let ordered = corral.members.sorted { $0.zOrderIndex < $1.zOrderIndex }

        // AX-tracked restores (non-browser windows we moved via
        // WindowMutator, plus browser windows we didn't need to touch
        // at all because their frame already matched). These are the
        // members that will participate in the AX z-order raise pass.
        var restoredForZOrder: [(member: CorralMember, axElement: AXUIElement)] = []
        // Browser members restored via AppleScript that don't have an
        // AX element to raise. They end up in the correct relative
        // slot naturally: newly-opened windows are on top after
        // creation, and every subsequent AX raise on another member
        // pushes them one slot back.
        var restoredWithoutAX: Int = 0
        var missing: [String] = []
        var axCache: [pid_t: [EnumeratedWindow]] = [:]

        // For each browser bundle in this corral, decide once whether
        // the URL-overlap snapshot is worth running. If the browser
        // has zero visible windows now, there's nothing to reuse — we
        // skip the snapshot for every member of that bundle. Even
        // once we've started creating new windows via AppleScript,
        // subsequent members shouldn't try to reuse those (they're
        // ours, not user-owned pre-existing windows), so the
        // "empty at start" decision stays sticky per restore session.
        var browserStartedEmpty: [String: Bool] = [:]
        for member in ordered where member.tabs != nil && !(member.tabs?.isEmpty ?? true) {
            if browserStartedEmpty[member.appBundleID] == nil {
                browserStartedEmpty[member.appBundleID] = !hasVisibleWindow(bundleID: member.appBundleID)
            }
        }

        for (idx, member) in ordered.enumerated() {
            Log.corral.info(
                "Restore [\(idx + 1, privacy: .public)/\(ordered.count, privacy: .public)] '\(member.appName, privacy: .public)' (\(member.appBundleID, privacy: .public), slot \(member.zOrderIndex, privacy: .public))"
            )
            if let tabs = member.tabs, !tabs.isEmpty {
                let skipOverlap = browserStartedEmpty[member.appBundleID] ?? false
                let result = restoreBrowserMember(member: member, tabs: tabs, skipOverlapCheck: skipOverlap)
                switch result {
                case .movedExisting:
                    Log.corral.info("  → matched & moved existing browser window")
                    restoredWithoutAX += 1
                case .openedNew:
                    Log.corral.info("  → opened new browser window with \(tabs.count, privacy: .public) tab(s)")
                    restoredWithoutAX += 1
                case .failed:
                    Log.corral.error("  → browser restore failed")
                    missing.append(member.appName)
                }
            } else {
                if let axElement = findWindow(for: member, axCache: &axCache) {
                    WindowMutator.setFrame(member.frame, of: axElement)
                    Log.corral.info("  → moved via AX")
                    restoredForZOrder.append((member, axElement))
                } else {
                    Log.corral.error("  → no matching window found")
                    missing.append(member.appName)
                }
            }
        }

        let totalRestored = restoredForZOrder.count + restoredWithoutAX

        // If anything's still missing and we haven't retried yet,
        // wait 2s more and try again. Catalyst apps like Notes and
        // Podcasts have been observed to take 3–4s to spawn a window
        // in response to `open -b` reopen — longer than our initial
        // 2s prep delay. A single retry pass usually catches them
        // without dragging the fast-path save/restore experience
        // out for everyone.
        if allowRetry && !missing.isEmpty {
            Log.corral.info(
                "Restore: \(missing.count, privacy: .public) member(s) missing after first pass — retrying in 2s"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.executeRestore(of: corral, allowRetry: false)
            }
            return
        }

        enforceRestoreZOrder(restored: restoredForZOrder)
        Log.corral.notice(
            "Restore complete: \(totalRestored, privacy: .public)/\(corral.members.count, privacy: .public) restored, \(missing.count, privacy: .public) missing"
        )

        // Take down the "Restoring…" progress toast so it doesn't
        // stack visually with the result toast.
        progressToast?.dismissNow()
        progressToast = nil

        showRestoreResultToast(
            name: corral.name,
            restoredCount: totalRestored,
            total: corral.members.count,
            missing: missing
        )
    }

    /// Non-browser lookup. Fetches the owning app's AX windows once
    /// per PID (cached) and matches by title. Exact match wins, then
    /// substring match either direction; last-resort fallback is
    /// "first window" so a Notes doc gets restored even if the title
    /// changed since save.
    private func findWindow(
        for member: CorralMember,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: member.appBundleID).first else {
            Log.corral.info(
                "Restore: app \(member.appBundleID, privacy: .public) not running — skipping"
            )
            return nil
        }
        let pid = app.processIdentifier

        let axWindows: [EnumeratedWindow]
        if let cached = axCache[pid] {
            axWindows = cached
        } else {
            axWindows = AXWindowEnumerator.windows(of: app)
            axCache[pid] = axWindows
        }

        guard !axWindows.isEmpty else { return nil }

        // Match by title if we saved one.
        if !member.windowTitle.isEmpty {
            for win in axWindows {
                if readTitle(of: win.axElement) == member.windowTitle {
                    return win.axElement
                }
            }
            // Substring fallback — titles that shifted slightly
            // (e.g. "Untitled — Edited" vs "Untitled") still match.
            for win in axWindows {
                let current = readTitle(of: win.axElement)
                if current.isEmpty { continue }
                if current.contains(member.windowTitle)
                    || member.windowTitle.contains(current) {
                    return win.axElement
                }
            }
        }

        // Last resort: any window of this app is better than no
        // restore at all.
        return axWindows.first?.axElement
    }

    /// Outcome of a browser restore. Both success cases position the
    /// window entirely through AppleScript so we don't need an AX
    /// element (previously we tried to hunt the newly-opened window
    /// down via a frame match, which was flaky and produced
    /// false-negatives that got surfaced to the user as "not
    /// available" even though the AppleScript succeeded).
    private enum BrowserRestoreResult {
        case movedExisting
        case openedNew
        case failed
    }

    /// Browser lookup. Snapshots the browser (uses cache if fresh),
    /// finds the window with the highest URL-set overlap against the
    /// saved tabs, and — if that overlap is meaningful (≥ 50% of
    /// saved URLs present) — repositions that window in place via
    /// `BrowserScripting.moveBrowserWindow` (which addresses the
    /// window by its scripting-dictionary id, avoiding the AX frame
    /// mismatch pitfall). Otherwise opens a fresh browser window
    /// with the saved tabs via AppleScript.
    private func restoreBrowserMember(
        member: CorralMember,
        tabs: [TabInfo],
        skipOverlapCheck: Bool
    ) -> BrowserRestoreResult {
        let targetBoundsAX = CoordinateSpace.axRect(fromCocoa: member.frame)

        // When the browser had zero visible windows at restore start,
        // there's nothing to reuse — every member goes straight to
        // openBrowserWindow. Skipping the snapshot saves ~1s per
        // member of walking Chrome's hidden helper windows, and also
        // avoids the 5s timeout that fires on the Nth member when the
        // N-1 windows we just created have grown the snapshot pool
        // past what Chrome can enumerate under the timeout.
        if skipOverlapCheck {
            Log.corral.info("  browser: skipping URL-overlap snapshot (browser started empty)")
        } else if let snapshots = BrowserScripting.snapshotBrowserWindows(bundleID: member.appBundleID) {
            let savedURLs = Set(tabs.map { $0.url })
            let ranked = snapshots
                .map { snap -> (snap: BrowserScripting.BrowserWindowSnapshot, overlap: Int) in
                    let currentURLs = Set(snap.tabs.map { $0.url })
                    return (snap, savedURLs.intersection(currentURLs).count)
                }
                .max(by: { $0.overlap < $1.overlap })

            let overlapThreshold = max(1, tabs.count / 2)
            if let best = ranked, best.overlap >= overlapThreshold {
                Log.corral.info(
                    "  browser match: \(best.overlap, privacy: .public)/\(tabs.count, privacy: .public) URL overlap, window id \(best.snap.internalID, privacy: .public)"
                )
                let moved = BrowserScripting.moveBrowserWindow(
                    bundleID: member.appBundleID,
                    windowID: best.snap.internalID,
                    boundsAX: targetBoundsAX
                )
                if moved {
                    return .movedExisting
                }
                Log.corral.info("  move-existing failed — falling back to open new")
            } else {
                Log.corral.info(
                    "  browser: no matched window (best overlap \(ranked?.overlap ?? 0, privacy: .public)/\(tabs.count, privacy: .public), threshold \(overlapThreshold, privacy: .public))"
                )
            }
        } else {
            Log.corral.info("  browser: snapshotBrowserWindows returned nil — opening fresh")
        }

        let opened = BrowserScripting.openBrowserWindow(
            bundleID: member.appBundleID,
            tabs: tabs,
            boundsAX: targetBoundsAX
        )
        if opened { return .openedNew }

        // AppleScript path failed. Fall back to `/usr/bin/open -a
        // "<AppName>" URL1 URL2 …` which uses LaunchServices, doesn't
        // touch AppleScript / TCC-Automation, and just tells the browser
        // "open these URLs." Chrome-family and Safari all accept URL
        // lists this way; when the browser is running with no visible
        // windows this creates one, matching the user intent. The window
        // won't land at the exact saved frame (that would need
        // AppleScript to set bounds), but the tabs come back — which
        // is the piece the user cares most about.
        if openBrowserURLsViaLaunchServices(bundleID: member.appBundleID, tabs: tabs) {
            return .openedNew
        }
        return .failed
    }

    /// Dispatches to the right `/usr/bin/open` invocation for the
    /// given bundle. Most non-browser apps (Notes, Podcasts, Slack,
    /// Discord, etc.) accept plain `open -b <bundle>` and use their
    /// own `applicationShouldHandleReopen` handler to create a
    /// default window. But some are quirky:
    ///
    /// - **Browsers** (Chrome + family, Safari): `open -b <bundle>`
    ///   on a running instance doesn't produce a window. We pass
    ///   URLs — the saved tab list if we have one, otherwise
    ///   `about:blank` — via `open -b <bundle> URL1 URL2 …`. The
    ///   URLs land as tabs in a fresh window, matching user intent.
    ///
    /// - **Finder**: `applicationShouldHandleReopen` doesn't trigger
    ///   for Finder because it always "has" the Desktop pseudo-
    ///   window (which we filter). Open a folder path (home) so a
    ///   real Finder browser window appears.
    private func openAppForRestore(
        bundleID: String,
        membersOfBundle: [CorralMember]
    ) {
        // If this bundle already has visible windows, don't `open`
        // it — the app's fine, we'll just find and reposition its
        // existing window in the execute step. Skipping here prevents
        // two real bugs:
        //   1. Chrome window multiplication: each `open -b Chrome
        //      about:blank` on a Chrome that already has windows
        //      creates a NEW window, so 3 rapid releases produced
        //      6 windows piled on top of each other.
        //   2. Rapid-fire re-releases (user double-clicks the corral):
        //      the second `open -b <bundle>` fires while the first is
        //      still processing; macOS silently drops the second, and
        //      the app that was reopening gets confused.
        if hasVisibleWindow(bundleID: bundleID) {
            Log.corral.info(
                "Restore prep: \(bundleID, privacy: .public) already has visible window(s) — skipping open"
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        if BrowserScripting.isSupportedBrowser(bundleID: bundleID) {
            // Browsers: launch/activate WITHOUT URLs. Passing URLs
            // here caused Chrome to collapse every tab from every
            // saved member into a single merged window, which then
            // sat on top of the per-member windows that
            // restoreBrowserMember's openChromiumWindowScript creates
            // (via `activate` + `make new window`) with the correct
            // per-window tab lists. Result was N+1 Chrome windows
            // instead of N.
            //
            // For running-windowless Chrome (`open -b` alone doesn't
            // create a window), openChromiumWindowScript's `activate`
            // + `make new window` still creates the correct windows.
            // For not-running Chrome, `open -b` launches it (Chrome
            // may create its default window); the per-member AppleScript
            // then adds ours. Users see the default window as one extra
            // — acceptable trade-off vs. the merged-tabs bug.
            _ = membersOfBundle  // tabs are handled per-member downstream
            process.arguments = ["-b", bundleID]
            Log.corral.info(
                "Restore prep: /usr/bin/open -b \(bundleID, privacy: .public) (browser — tabs handled per-member downstream)"
            )
        } else if bundleID == "com.apple.finder" {
            // Finder: needs a folder path to create a real window
            // (the Desktop backdrop doesn't count).
            let homePath = NSString(string: "~").expandingTildeInPath
            process.arguments = [homePath]
            Log.corral.info(
                "Restore prep: /usr/bin/open \(homePath, privacy: .public) (Finder home)"
            )
        } else {
            // Default: reopen-hook path for well-behaved apps.
            process.arguments = ["-b", bundleID]
            Log.corral.info(
                "Restore prep: /usr/bin/open -b \(bundleID, privacy: .public) (default reopen)"
            )
        }

        do {
            try process.run()
        } catch {
            Log.corral.error(
                "Failed to spawn open for \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Shows a one-time-per-session alert when a browser's snapshot
    /// script silently returns empty. Explains what's happening (TCC
    /// grant is stale) and points the user at the manual toggle in
    /// System Settings — the only reliable way to reset it, since
    /// `tccutil reset` has been observed to freeze macOS.
    private func notifyBrowserScriptingBrokenOnce(bundleID: String) {
        guard !scriptingFailureNotified.contains(bundleID) else { return }
        scriptingFailureNotified.insert(bundleID)

        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String } ?? bundleID
        Log.corral.notice(
            "Browser scripting broken for \(bundleID, privacy: .public) — showing settings alert"
        )
        let alert = NSAlert()
        alert.messageText = "Can't read tabs from \(appName)"
        alert.informativeText = """
            Window Wrangler asked macOS for permission to control \(appName), and macOS says the permission is granted — but the actual scripting call returns nothing. This usually means \(appName)'s Automation entry got into a stale state from a previous version of the app.

            To reset it: open System Settings > Privacy & Security > Automation, find Window Wrangler, and toggle \(appName) off and back on. Then try saving again.

            (Corrals will still save the \(appName) window's position — you just won't get the tab list back on restore.)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AutomationPermission.openSystemSettings()
        }
    }

    /// True if the app with the given bundle-ID is currently running
    /// AND has at least one AX-visible window that survives our
    /// enumerator filters (the Finder Desktop pseudo-window and other
    /// backdrops don't count).
    private func hasVisibleWindow(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        let windows = AXWindowEnumerator.windows(of: app)
        return !windows.isEmpty
    }

    /// LaunchServices fallback for browser restore when AppleScript
    /// is unavailable (stale TCC record, permission denied without
    /// prompt, Chrome-specific hang, etc). Returns true on success.
    private func openBrowserURLsViaLaunchServices(bundleID: String, tabs: [TabInfo]) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let appName = Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String else {
            return false
        }
        let urls = tabs.map(\.url)
        guard !urls.isEmpty else { return false }
        Log.corral.info(
            "LaunchServices browser restore: /usr/bin/open -a '\(appName, privacy: .public)' \(urls.count, privacy: .public) URL(s)"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName] + urls
        do {
            try process.run()
            return true
        } catch {
            Log.corral.error(
                "LaunchServices browser restore failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Raises windows in reverse-slot order so `zOrderIndex == 0`
    /// (the anchor) ends up on top after every raise has completed —
    /// same pattern the cascade uses in
    /// `CascadeOrchestrator.enforceCascadeZOrder`.
    private func enforceRestoreZOrder(
        restored: [(member: CorralMember, axElement: AXUIElement)]
    ) {
        // Sort descending by zOrderIndex (backmost first) so the
        // frontmost gets raised LAST and ends up on top of the stack.
        let ordered = restored.sorted { $0.member.zOrderIndex > $1.member.zOrderIndex }
        for entry in ordered {
            AXUIElementPerformAction(entry.axElement, kAXRaiseAction as CFString)
        }
    }

    /// Reads a window's title via AX. Empty string on failure.
    private func readTitle(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return "" }
        return title
    }

    // MARK: - Restore result toast

    /// Shows the outcome of a restore. All good → green "✓ Restored
    /// 'NAME'". Partial success → longer message that includes the
    /// missing app names ("… — Messages, Notes not available") and
    /// holds slightly longer so the user can read it.
    private func showRestoreResultToast(name: String, restoredCount: Int, total: Int, missing: [String]) {
        let text: String
        let hold: TimeInterval
        if missing.isEmpty {
            text = "✓  Restored '\(name)'"
            hold = 1.4
        } else {
            let missingList = missing.joined(separator: ", ")
            text = "Restored \(restoredCount)/\(total) of '\(name)' — \(missingList) not available"
            hold = 3.0
        }
        let toast = CorralToast()
        toast.showMessage(text, style: .success, holdSeconds: hold) { [weak self] in
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

            // Document path (for documents-based apps). Read from AX
            // by matching the visible-window frame back to the app's
            // AX enumeration, then querying kAXDocumentAttribute on
            // that element. Nil for apps that don't expose it — that
            // path degrades cleanly to "launch the app and hope its
            // auto-restore brings back the window."
            let docPath = resolveDocumentPath(for: win, axCache: &axCache)

            members.append(
                CorralMember(
                    appBundleID: bundleID,
                    appName: appName,
                    windowTitle: title,
                    frame: win.frame,
                    zOrderIndex: idx,
                    tabs: tabs,
                    documentPath: docPath
                )
            )
        }
        return members
    }

    /// Reads `kAXDocumentAttribute` for the AX element whose frame
    /// matches this visible window. Returns a POSIX file path if the
    /// attribute is available and parses as a file URL; nil for apps
    /// that don't expose it (Messages, Discord, Notes' bespoke object
    /// model, Finder browser windows, etc.).
    private func resolveDocumentPath(
        for window: VisibleWindow,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> String? {
        let axWindows: [EnumeratedWindow]
        if let cached = axCache[window.ownerPID] {
            axWindows = cached
        } else if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            axWindows = AXWindowEnumerator.windows(of: app)
            axCache[window.ownerPID] = axWindows
        } else {
            return nil
        }
        guard let matched = axWindows.first(where: {
            Self.framesMatch($0.frame, window.frame, tolerance: 4)
        }) else {
            return nil
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            matched.axElement,
            kAXDocumentAttribute as CFString,
            &value
        )
        guard result == .success, let str = value as? String else { return nil }
        // kAXDocumentAttribute typically returns a file URL string
        // like "file:///Users/jmw3/Desktop/foo.txt". Convert to a
        // POSIX path so restore can pass it directly to
        // NSWorkspace.open without needing another URL parse.
        if let url = URL(string: str), url.isFileURL {
            return url.path
        }
        return nil
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

    /// Tracks browser bundles whose scripting appears broken this
    /// session (permission granted but AppleScript returns empty).
    /// We show an actionable alert once per bundle so users know to
    /// reset Automation for that browser in System Settings — not
    /// every save (which would be spammy).
    private var scriptingFailureNotified: Set<String> = []

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
        _ = cache  // full-snapshot cache no longer used at save time

        // Targeted snapshot: bounds-only enumeration (fast, no per-
        // window tab access on the browser's hidden helper windows)
        // → find best-matching window → tabs-for-that-window only.
        // Replaces the "one big walk-every-window-and-every-tab
        // script" approach that Chrome silently returned "" from
        // when the user had 30+ Chrome windows.
        let targetAX = CoordinateSpace.axRect(fromCocoa: cocoaFrame)
        guard let match = BrowserScripting.snapshotBrowserWindowNearFrame(
            bundleID: bundleID,
            targetBoundsAX: targetAX
        ) else {
            // Log-only. Saves only trigger while lasso mode is on, so
            // any NSAlert we present here would appear behind the
            // lasso overlay window (which sits at NSStatusWindowLevel)
            // and be click-blocked — a dead-end UX. With the targeted
            // snapshot in place, "no match" is much rarer than it was
            // in the full-snapshot era; a saved corral without tab
            // data is a degraded-but-usable outcome (browser window
            // restores empty on release, other members restore
            // normally).
            Log.corral.info(
                "No targeted browser match for \(bundleID, privacy: .public) — target=(\(Int(targetAX.minX), privacy: .public),\(Int(targetAX.minY), privacy: .public) \(Int(targetAX.width), privacy: .public)×\(Int(targetAX.height), privacy: .public))"
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
    ///
    /// Suspends the CGEventTap around the modal so the alert is
    /// clickable during lasso mode — without this, our tap consumes
    /// the click on the "OK" button and the user has to keyboard-
    /// dismiss with Return / Escape.
    private func showAlert(title: String, message: String) {
        suspendMouseCapture()
        defer { resumeMouseCapture() }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
