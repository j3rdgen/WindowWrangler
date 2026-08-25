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

    init(
        store: CorralStore,
        selection: WindowSelection,
        isTrusted: @escaping () -> Bool
    ) {
        self.store = store
        self.selection = selection
        self.isTrusted = isTrusted
    }

    // MARK: - Public entry point

    /// Called by ⌃⌥⌘S and the "Corral (Save Window Group)" menu
    /// item. Runs preflight; if it passes, presents the name pill.
    /// Returns immediately — the actual save happens asynchronously
    /// after the user hits Return.
    func beginSave() {
        Log.corral.notice("beginSave requested")

        guard isTrusted() else {
            showAlert(
                title: "Accessibility permission required",
                message: "Grant Window Wrangler access to Accessibility in System Settings, then try again."
            )
            return
        }

        guard !selection.isEmpty else {
            showAlert(
                title: "No windows selected",
                message: "Turn on Lasso Mode with ⌃⌥⌘C, drag to select windows, then press ⌃⌥⌘S to save them as a group."
            )
            return
        }

        if store.isAtCap {
            showAlert(
                title: "Group limit reached",
                message: "You have \(CorralStore.maxCorrals) saved groups. Delete one before creating a new one."
            )
            return
        }

        // Snapshot the ordered selection now so a stray click during
        // name entry can't mutate what we're about to save.
        let frozenSelection = selection.ordered
        presentNamePill(frozenSelection: frozenSelection)
    }

    // MARK: - Name entry

    private func presentNamePill(frozenSelection: [VisibleWindow]) {
        let pill = CorralNamePill()
        pill.onSubmit = { [weak self] name in
            self?.namePill = nil
            self?.completeSave(name: name, frozenSelection: frozenSelection)
        }
        pill.onCancel = { [weak self] in
            self?.namePill = nil
            Log.corral.info("Save cancelled by user")
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
                openAppForRestore(bundleID: bundleID)
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

        // Plan browser assignments UP FRONT — before any move — per
        // spec Part 5. Fetch one snapshot per browser bundleID,
        // intersect with the current-Desktop on-screen inventory to
        // filter out other-Desktop windows, then greedy-assign
        // one-to-one by URL-overlap score. Chrome's AppleScript
        // window indices can shift after `set bounds`, so all
        // matching MUST complete before any window moves.
        let browserBundleIDs: Set<String> = Set(
            ordered
                .filter { $0.tabs != nil && !($0.tabs?.isEmpty ?? true) }
                .map(\.appBundleID)
        )
        // Assignments keyed by (bundleID, zOrderIndex) — unique per
        // member within a corral. CorralMember isn't Hashable itself
        // (it's a value type without an id), so we key on the fields
        // that are guaranteed unique per member.
        var browserAssignmentsByMember: [String: BrowserRestoreAssignment] = [:]
        func assignmentKey(_ m: CorralMember) -> String {
            "\(m.appBundleID)#\(m.zOrderIndex)"
        }
        var totalOffDesktopIgnored = 0
        for bundleID in browserBundleIDs {
            let membersForBundle = ordered.filter { $0.appBundleID == bundleID && !($0.tabs?.isEmpty ?? true) }
            let snapshots = BrowserScripting.snapshotBrowserWindows(bundleID: bundleID) ?? []
            let candidates = buildBrowserRestoreCandidates(bundleID: bundleID, snapshots: snapshots)
            let asAppleScriptSaw = snapshots.count
            let asLocallyEligible = candidates.count
            let offDesktop = max(0, asAppleScriptSaw - asLocallyEligible)
            totalOffDesktopIgnored += offDesktop
            let assignments = planBrowserAssignments(members: membersForBundle, candidates: candidates)
            for a in assignments {
                browserAssignmentsByMember[assignmentKey(a.member)] = a
            }
            let reusedCount = assignments.filter { $0.candidate != nil }.count
            let newCount = assignments.count - reusedCount
            Log.corral.info(
                "Browser restore plan: bundle=\(bundleID, privacy: .public) members=\(membersForBundle.count, privacy: .public) asWindows=\(asAppleScriptSaw, privacy: .public) locallyEligible=\(asLocallyEligible, privacy: .public) reused=\(reusedCount, privacy: .public) new=\(newCount, privacy: .public) offDesktopIgnored=\(offDesktop, privacy: .public)"
            )
        }

        // AX-tracked restores (non-browser windows we moved via
        // WindowMutator, plus browser windows we didn't need to touch
        // at all because their frame already matched with tab-verified
        // identity). These are the members that will participate in
        // the AX z-order raise pass.
        var restoredForZOrder: [(member: CorralMember, axElement: AXUIElement)] = []
        // Browser members restored via AppleScript that don't have an
        // AX element to raise. They end up in the correct relative
        // slot naturally: newly-opened windows are on top after
        // creation, and every subsequent AX raise on another member
        // pushes them one slot back.
        var restoredWithoutAX: Int = 0
        var browserReusedCount: Int = 0
        var browserOpenedCount: Int = 0
        var browserAlreadyAtTarget: Int = 0
        var missing: [String] = []
        var axCache: [pid_t: [EnumeratedWindow]] = [:]

        for (idx, member) in ordered.enumerated() {
            Log.corral.info(
                "Restore [\(idx + 1, privacy: .public)/\(ordered.count, privacy: .public)] '\(member.appName, privacy: .public)' (\(member.appBundleID, privacy: .public), slot \(member.zOrderIndex, privacy: .public))"
            )
            let isBrowser = member.tabs != nil && !(member.tabs?.isEmpty ?? true)
            let assignment = browserAssignmentsByMember[assignmentKey(member)]

            // Browser members: use browser-aware "already at target"
            // — the candidate MUST both (a) be at the target frame
            // AND (b) have tab match. Frame-only match is not
            // enough for browser members per spec Part 4.
            //
            // Non-browser members: keep the existing frame-only
            // idempotency check. A generic app window at the target
            // frame is a legitimate "already restored" signal.
            if isBrowser {
                if let match = assignment?.candidate,
                   Self.framesMatch(match.boundsCocoa, member.frame, tolerance: 30) {
                    Log.corral.info("  → browser already at target with matching tabs — skipping (score \(assignment?.score ?? 0, privacy: .public))")
                    browserAlreadyAtTarget += 1
                    restoredWithoutAX += 1
                    continue
                }
            } else if alreadyAtTarget(member: member) {
                Log.corral.info("  → already at target — skipping")
                restoredWithoutAX += 1
                continue
            }

            if isBrowser {
                // Browser member: execute the planned assignment.
                // Either move the assigned candidate or open new.
                if let candidate = assignment?.candidate {
                    let targetBoundsAX = CoordinateSpace.axRect(fromCocoa: member.frame)
                    let moved = BrowserScripting.moveBrowserWindow(
                        bundleID: member.appBundleID,
                        windowID: candidate.appleScriptInternalID,
                        boundsAX: targetBoundsAX
                    )
                    if moved {
                        Log.corral.info("  → reused local browser window (score \(assignment?.score ?? 0, privacy: .public))")
                        browserReusedCount += 1
                        restoredWithoutAX += 1
                    } else {
                        // Move failed — fall through to open-new so
                        // the member still gets restored somewhere.
                        Log.corral.info("  → move-existing failed, opening new instead")
                        let opened = BrowserScripting.openBrowserWindow(
                            bundleID: member.appBundleID,
                            tabs: member.tabs ?? [],
                            boundsAX: targetBoundsAX
                        )
                        if opened {
                            browserOpenedCount += 1
                            restoredWithoutAX += 1
                        } else if openBrowserURLsViaLaunchServices(bundleID: member.appBundleID, tabs: member.tabs ?? []) {
                            browserOpenedCount += 1
                            restoredWithoutAX += 1
                        } else {
                            missing.append(member.appName)
                        }
                    }
                } else {
                    // No local match — open new (spec Part 6:
                    // "Never take a matching window from another
                    // Desktop").
                    let targetBoundsAX = CoordinateSpace.axRect(fromCocoa: member.frame)
                    let opened = BrowserScripting.openBrowserWindow(
                        bundleID: member.appBundleID,
                        tabs: member.tabs ?? [],
                        boundsAX: targetBoundsAX
                    )
                    if opened {
                        Log.corral.info("  → opened new browser window with \(member.tabs?.count ?? 0, privacy: .public) tab(s)")
                        browserOpenedCount += 1
                        restoredWithoutAX += 1
                    } else if openBrowserURLsViaLaunchServices(bundleID: member.appBundleID, tabs: member.tabs ?? []) {
                        Log.corral.info("  → opened new browser window via LaunchServices")
                        browserOpenedCount += 1
                        restoredWithoutAX += 1
                    } else {
                        Log.corral.error("  → browser restore failed")
                        missing.append(member.appName)
                    }
                }
            } else {
                // Non-browser member: AX move.
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

        // Scatter audit: for each restored member, is a window
        // matching its saved frame actually visible on the CURRENT
        // Desktop? Windows that got AX-moved on other Desktops
        // succeeded logically but aren't here for the user. Anything
        // in `missing` is already accounted for elsewhere, so audit
        // only the ones we count as restored.
        let restoredMembers = corral.members.filter { !missing.contains($0.appName) }
        let scatterCount = countMembersOnOtherDesktops(restoredMembers)

        Log.corral.notice(
            "Restore complete: \(totalRestored, privacy: .public)/\(corral.members.count, privacy: .public) restored — browserReused=\(browserReusedCount, privacy: .public), browserOpened=\(browserOpenedCount, privacy: .public), browserAlreadyAtTarget=\(browserAlreadyAtTarget, privacy: .public), offDesktopIgnored=\(totalOffDesktopIgnored, privacy: .public), missing=\(missing.count, privacy: .public), onOtherDesktops=\(scatterCount, privacy: .public)"
        )

        // Take down the "Restoring…" progress toast so it doesn't
        // stack visually with the result toast.
        progressToast?.dismissNow()
        progressToast = nil

        showRestoreResultToast(
            name: corral.name,
            restoredCount: totalRestored,
            total: corral.members.count,
            missing: missing,
            scatterCount: scatterCount
        )
    }

    /// Counts members whose saved frame doesn't correspond to any
    /// window currently visible on the current Desktop. Uses
    /// `CGWindowListOnScreenOnly` (via CrossAppWindowEnumerator)
    /// which filters to current-Space windows only. Frame proximity
    /// tolerance is generous (30pt) because some apps clamp the
    /// requested frame slightly (Chrome's min-width, Notes' aspect
    /// preferences, etc.).
    ///
    /// Browser members are excluded from the audit: our restore
    /// paths for browsers (AppleScript `make new window` /
    /// `set bounds`, and the LaunchServices `open -b` fallback) all
    /// spawn or move windows on the current Space by design.
    /// Chrome/Safari frequently clamp or offset the requested frame
    /// (min-width, missing chrome preserved from the last-used
    /// window), so a frame-mismatch does NOT indicate the window
    /// landed on another Desktop — it just indicates the browser
    /// picked its own bounds. Counting browsers here produced false
    /// "N on other Desktops" toasts on every browser restore.
    private func countMembersOnOtherDesktops(_ members: [CorralMember]) -> Int {
        let currentDesktopWindows = CrossAppWindowEnumerator.allVisibleWindows()
        return members.filter { member in
            let isBrowser = member.tabs != nil && !(member.tabs?.isEmpty ?? true)
            if isBrowser { return false }
            return !currentDesktopWindows.contains(where: {
                Self.framesMatch($0.frame, member.frame, tolerance: 30)
            })
        }.count
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
        // Iterate ALL PIDs for this bundleID — Console and some
        // other Apple apps can have multiple concurrent PIDs, and
        // window ownership can land on any of them. Use the first
        // PID whose AX enumeration returns non-empty windows.
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: member.appBundleID)
        guard !apps.isEmpty else {
            Log.corral.info(
                "Restore: app \(member.appBundleID, privacy: .public) not running — skipping"
            )
            return nil
        }
        var axWindows: [EnumeratedWindow] = []
        for app in apps {
            let pid = app.processIdentifier
            let candidate: [EnumeratedWindow]
            if let cached = axCache[pid] {
                candidate = cached
            } else {
                candidate = AXWindowEnumerator.windows(of: app)
                axCache[pid] = candidate
            }
            if !candidate.isEmpty {
                axWindows = candidate
                break
            }
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

    // MARK: - Restore planning types

    /// One reusable browser window from the current Desktop's
    /// on-screen inventory intersected with the browser's AppleScript
    /// snapshot. Windows that AppleScript reports but aren't in the
    /// on-screen inventory (i.e. live on another Desktop) never
    /// become candidates — spec Part 3.
    private struct BrowserRestoreCandidate {
        let bundleID: String
        /// CGWindowID from CGWindowList — stable across the plan
        /// (unlike Chrome's AppleScript window indices, which can
        /// shift after `set bounds`).
        let windowID: CGWindowID
        /// The AppleScript-side identity, used by
        /// `BrowserScripting.moveBrowserWindow`.
        let appleScriptInternalID: Int
        let boundsCocoa: CGRect
        let tabs: [TabInfo]
    }

    /// One planned assignment. `candidate == nil` means "no valid
    /// local reuse — open a new window."
    private struct BrowserRestoreAssignment {
        let member: CorralMember
        let candidate: BrowserRestoreCandidate?
        /// Match score in the winning assignment. Zero for
        /// open-new (no candidate).
        let score: Int
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

        // Browser started empty → nothing to reuse, skip the snapshot
        // (saves ~1s per member of walking Chrome's helper windows).
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

    // MARK: - Restore planning helpers (browser members)

    /// Currently-visible windows for the given bundle on the CURRENT
    /// Desktop, keyed by CGWindowID. Uses `CGWindowListCopyWindowInfo`
    /// with `.optionOnScreenOnly` so windows on other Spaces / other
    /// Desktops (with "Displays have separate Spaces" on) are excluded.
    /// This is what makes the restore planner refuse to reuse a
    /// matching browser window that lives on another Desktop — spec
    /// Part 3.
    private func onScreenWindowsForBundle(_ bundleID: String) -> [CGWindowID: CGRect] {
        // PIDs of all currently-running instances of this bundle.
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { return [:] }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var out: [CGWindowID: CGRect] = [:]
        for entry in raw {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = entry[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            // CGWindowList bounds are in AX-style top-left global.
            let ax = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            out[winID] = CoordinateSpace.cocoaRect(fromAX: ax)
        }
        return out
    }

    /// Builds the pool of candidate windows for restore matching by
    /// intersecting the browser's AppleScript snapshot with the
    /// current-Desktop on-screen inventory. AppleScript-visible
    /// windows that DON'T appear in the on-screen list are dropped —
    /// they live on another Desktop and per spec must NOT be moved.
    private func buildBrowserRestoreCandidates(
        bundleID: String,
        snapshots: [BrowserScripting.BrowserWindowSnapshot]
    ) -> [BrowserRestoreCandidate] {
        let onScreen = onScreenWindowsForBundle(bundleID)
        guard !onScreen.isEmpty else { return [] }
        // Match snapshots to CGWindowList entries by frame (both
        // sides are in Cocoa global after conversion). AppleScript
        // rounds bounds to integers; CGWindowList to floats — 30pt
        // tolerance matches the existing framesMatch policy.
        var candidates: [BrowserRestoreCandidate] = []
        var usedCGWindowIDs: Set<CGWindowID> = []
        for snap in snapshots {
            let cocoaFrame = CoordinateSpace.cocoaRect(fromAX: snap.boundsAX)
            let hit = onScreen.first(where: { (winID, frame) in
                !usedCGWindowIDs.contains(winID)
                    && Self.framesMatch(frame, cocoaFrame, tolerance: 30)
            })
            guard let (winID, frame) = hit else { continue }
            usedCGWindowIDs.insert(winID)
            candidates.append(BrowserRestoreCandidate(
                bundleID: bundleID,
                windowID: winID,
                appleScriptInternalID: snap.internalID,
                boundsCocoa: frame,
                tabs: snap.tabs
            ))
        }
        return candidates
    }

    /// Scores a (member, candidate) pair. Higher = better. Zero or
    /// negative means "no meaningful match — prefer open-new."
    ///
    /// Scoring tiers (in decreasing weight):
    /// 1. Full normalized-URL match:  100 pts each
    /// 2. Hostname-only match:         20 pts each (fallback for
    ///    URLs that redirected after load — Facebook, Google login
    ///    flows, OAuth handoffs, etc. Saved URL and loaded URL
    ///    share the host but not the path.)
    /// 3. Frame closeness bonus:      up to 10 pts
    ///
    /// Weak-signal URLs (about:blank, chrome://newtab) never
    /// contribute to either tier. Otherwise a random newtab window
    /// could match any saved window with a blank tab.
    ///
    /// Zero-score → open-new. A pure hostname match (no full-URL
    /// match) still returns a positive score if any distinctive host
    /// overlaps — enough to reuse the just-opened-and-redirected
    /// window on a follow-up restore of the same corral.
    private static func browserMatchScore(
        memberTabs: [TabInfo],
        candidateTabs: [TabInfo],
        memberFrame: CGRect,
        candidateFrame: CGRect
    ) -> Int {
        // Full-URL match.
        let savedFull = memberTabs.map { BrowserScripting.normalizedURL($0.url) }
        let candidateFull = candidateTabs.map { BrowserScripting.normalizedURL($0.url) }
        let savedFullSet = Set(savedFull)
        let candidateFullSet = Set(candidateFull)
        var fullOverlap = 0
        for url in savedFullSet where candidateFullSet.contains(url) {
            if BrowserScripting.isWeakSignalURL(url) { continue }
            fullOverlap += 1
        }

        // Hostname-only fallback — for URLs that redirect after
        // load. E.g. saved "https://www.facebook.com/", loaded
        // becomes "https://www.facebook.com/?rdr=..." — full URL
        // differs but host matches.
        let savedHosts = Set(savedFull.compactMap { host(fromNormalized: $0) })
        let candidateHosts = Set(candidateFull.compactMap { host(fromNormalized: $0) })
        var hostOverlap = 0
        for host in savedHosts where candidateHosts.contains(host) {
            // Skip weak-signal hosts (chrome://, about: etc — treat
            // as noise).
            if host.contains(":") { continue }
            hostOverlap += 1
        }
        // Don't double-count: URLs that already fully matched already
        // implicitly matched their host. Subtract fullOverlap so
        // hostOverlap only counts host-only matches.
        let hostOnlyOverlap = max(0, hostOverlap - fullOverlap)

        // Match VALIDITY gate — the score alone isn't enough to
        // decide reuse-vs-open-new; we need substantial identity
        // evidence to avoid hijacking an unrelated window that
        // happens to share one common hostname (gmail.com, etc.).
        //
        // A candidate is a valid reuse target iff:
        //   (a) at least one full-URL match — a canonical URL
        //       collision is essentially proof of identity, OR
        //   (b) hostname overlap covers ALL of the saved window's
        //       meaningful tabs — the post-redirect case, where
        //       every saved tab's host is still present in the
        //       candidate even though the exact URLs have shifted
        //       (Facebook, OAuth, single-page apps changing paths).
        //
        // A partial hostname overlap (e.g. 1 of 5 saved tabs) is
        // explicitly NOT enough. Before this gate existed, a random
        // Chrome window would be picked up and moved to the saved
        // position on restore because its only overlap was a
        // coincidental stale tab, which discarded the saved tabs
        // entirely.
        let meaningfulSavedTabCount = savedFullSet.filter { !BrowserScripting.isWeakSignalURL($0) }.count
        let isValidMatch = fullOverlap > 0
            || (meaningfulSavedTabCount > 0 && hostOverlap >= meaningfulSavedTabCount)
        guard isValidMatch else { return 0 }

        var score = fullOverlap * 100 + hostOnlyOverlap * 20

        // Small frame-closeness tiebreaker (max 10 pts).
        let dx = memberFrame.midX - candidateFrame.midX
        let dy = memberFrame.midY - candidateFrame.midY
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist < 200 {
            score += Int(10 - min(10, dist / 20))
        }
        return score
    }

    /// Extracts the host portion from a normalized URL, or nil if
    /// there isn't one (relative URLs, malformed). Used by
    /// `browserMatchScore` for hostname-only fallback matching.
    private static func host(fromNormalized normalized: String) -> String? {
        guard let comp = URLComponents(string: normalized),
              let host = comp.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    /// Plans one-to-one assignments between saved members and eligible
    /// on-screen candidates. Greedy: repeatedly picks the
    /// highest-scoring (member, candidate) pair, marks both consumed,
    /// stops when no positive-score pair remains. Members with no
    /// remaining match get `candidate = nil` (open new).
    private func planBrowserAssignments(
        members: [CorralMember],
        candidates: [BrowserRestoreCandidate]
    ) -> [BrowserRestoreAssignment] {
        // Score every pair once. O(N*M) — fine for typical corral sizes.
        struct Pair { let mi: Int; let ci: Int; let score: Int }
        var pairs: [Pair] = []
        for (mi, m) in members.enumerated() {
            for (ci, c) in candidates.enumerated() {
                let s = Self.browserMatchScore(
                    memberTabs: m.tabs ?? [],
                    candidateTabs: c.tabs,
                    memberFrame: m.frame,
                    candidateFrame: c.boundsCocoa
                )
                if s > 0 { pairs.append(Pair(mi: mi, ci: ci, score: s)) }
            }
        }
        pairs.sort { $0.score > $1.score }
        var assignedCandidate: [Int: Int] = [:]   // memberIndex → candidateIndex
        var takenCandidates: Set<Int> = []
        var takenMembers: Set<Int> = []
        for p in pairs {
            if takenMembers.contains(p.mi) || takenCandidates.contains(p.ci) { continue }
            assignedCandidate[p.mi] = p.ci
            takenMembers.insert(p.mi)
            takenCandidates.insert(p.ci)
        }
        // Convert to output; every member gets an assignment (nil = open new).
        return members.enumerated().map { (mi, m) in
            if let ci = assignedCandidate[mi] {
                let matchScore = pairs.first { $0.mi == mi && $0.ci == ci }?.score ?? 0
                return BrowserRestoreAssignment(
                    member: m,
                    candidate: candidates[ci],
                    score: matchScore
                )
            } else {
                return BrowserRestoreAssignment(member: m, candidate: nil, score: 0)
            }
        }
    }

    /// Dispatches to the right `/usr/bin/open` invocation for the
    /// given bundle. Most apps get plain `open -b <bundle>` and
    /// respond via `applicationShouldHandleReopen`. Finder is the one
    /// exception — it always "has" the Desktop pseudo-window, so
    /// reopen doesn't fire; we open a folder path (home) instead.
    ///
    /// Browsers deliberately also get plain `open -b` here — the
    /// per-member `openChromiumWindowScript` in `restoreBrowserMember`
    /// creates windows with correct per-window tab lists via
    /// AppleScript. Passing URLs at this layer previously caused
    /// Chrome to collapse every saved member's tabs into a single
    /// merged window layered on top of the correct ones.
    private func openAppForRestore(bundleID: String) {
        // Browsers: never call `open -b`. AppleScript's `make new
        // window` in restoreBrowserMember launches the app if
        // needed AND creates the window on the current Desktop
        // without triggering macOS's "activate switches to app's
        // Space" behavior — which would otherwise auto-swipe to
        // whatever Desktop the browser's front window is on when
        // the browser is running with windows elsewhere.
        if BrowserScripting.isSupportedBrowser(bundleID: bundleID) {
            Log.corral.info(
                "Restore prep: \(bundleID, privacy: .public) is a browser — deferring to AppleScript"
            )
            return
        }
        // Non-browsers: skip if the app already has a window on the
        // CURRENT Desktop — the execute step will find and reposition
        // it. If windows exist only on OTHER Desktops, we DO run
        // `open` so a fresh window has a chance of landing here.
        if hasWindowOnCurrentDesktop(bundleID: bundleID) {
            Log.corral.info(
                "Restore prep: \(bundleID, privacy: .public) already has window(s) on current Desktop — skipping open"
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        if bundleID == "com.apple.finder" {
            let homePath = NSString(string: "~").expandingTildeInPath
            process.arguments = [homePath]
            Log.corral.info(
                "Restore prep: /usr/bin/open \(homePath, privacy: .public) (Finder home)"
            )
        } else {
            process.arguments = ["-b", bundleID]
            Log.corral.info(
                "Restore prep: /usr/bin/open -b \(bundleID, privacy: .public)"
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

    /// True if the app has a window visible on the CURRENT Desktop
    /// (Space). Uses `CGWindowListOnScreenOnly` which filters to
    /// current-Space windows only. If the app is running with
    /// windows only on OTHER Desktops, this returns false — so
    /// callers force a fresh open that has a better chance of
    /// landing on the current Desktop instead of trying to reuse a
    /// window that would visually stay put on its Desktop while
    /// getting AX-moved to the saved frame there.
    private func hasWindowOnCurrentDesktop(bundleID: String) -> Bool {
        let ourApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !ourApps.isEmpty else { return false }
        let ourPIDs = Set(ourApps.map { $0.processIdentifier })
        return CrossAppWindowEnumerator.allVisibleWindows()
            .contains(where: { ourPIDs.contains($0.ownerPID) })
    }

    /// True if a window owned by this member's app is already at
    /// (approximately) the saved frame on the current Desktop.
    /// Idempotency check so the retry pass doesn't re-restore
    /// members the first pass already placed correctly — for
    /// browsers, that would create duplicate windows because the
    /// URL-overlap snapshot times out on the newly-busy browser.
    private func alreadyAtTarget(member: CorralMember) -> Bool {
        let ourApps = NSRunningApplication.runningApplications(withBundleIdentifier: member.appBundleID)
        guard !ourApps.isEmpty else { return false }
        let ourPIDs = Set(ourApps.map { $0.processIdentifier })
        return CrossAppWindowEnumerator.allVisibleWindows().contains {
            ourPIDs.contains($0.ownerPID)
                && Self.framesMatch($0.frame, member.frame, tolerance: 30)
        }
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
    private func showRestoreResultToast(name: String, restoredCount: Int, total: Int, missing: [String], scatterCount: Int) {
        let text: String
        let hold: TimeInterval
        let scatterNote = scatterCount > 0
            ? "; \(scatterCount) on other Desktops"
            : ""
        if missing.isEmpty && scatterCount == 0 {
            text = "✓  Restored '\(name)'"
            hold = 1.4
        } else if missing.isEmpty {
            text = "Restored '\(name)' — \(scatterCount) on other Desktops"
            hold = 2.5
        } else {
            let missingList = missing.joined(separator: ", ")
            text = "Restored \(restoredCount)/\(total) of '\(name)' — \(missingList) not available\(scatterNote)"
            hold = 3.0
        }
        let toast = CorralToast()
        toast.showMessage(text, style: .success, holdSeconds: hold) { [weak self] in
            self?.successToast = nil
        }
        successToast = toast
    }

    // MARK: - Member capture

    /// Per-save browser-snapshot context. Holds one cache-warm
    /// snapshot per bundleID and tracks which of its internal window
    /// IDs have already been assigned to a selected window this save.
    /// Prevents a single cached browser snapshot from satisfying two
    /// selected windows.
    private struct BrowserSaveCaptureContext {
        var snapshotsByBundleID: [String: [BrowserScripting.BrowserWindowSnapshot]] = [:]
        var consumedInternalIDsByBundleID: [String: Set<Int>] = [:]
    }

    /// Turns each `VisibleWindow` into a fully-populated
    /// `CorralMember`. Titles are resolved via AX (single
    /// enumeration cached per PID). Browser tabs are read from the
    /// prefetched cache (populated by the lasso coordinator's idle
    /// scheduler) — one cache read per browser bundleID for the
    /// whole selection, versus the old path's one targeted
    /// AppleScript pair per browser window.
    ///
    /// Falls back to `tabsForBrowserWindow` (targeted whose-filter)
    /// only when the cache miss / no-match / stale case truly needs
    /// a fresh fetch.
    private func captureMembers(from windows: [VisibleWindow]) -> [CorralMember] {
        var axCache: [pid_t: [EnumeratedWindow]] = [:]
        var browserContext = buildBrowserSaveContext(for: windows)
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

            let tabs = tabsForBrowserWindowUsingCache(
                bundleID: bundleID,
                cocoaFrame: win.frame,
                context: &browserContext
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

    /// Returns the AX element whose frame matches this visible
    /// window. Enumerates the owning app's AX windows once per PID
    /// (cached in `axCache`) and matches by frame within 4pt.
    private func axElement(
        for window: VisibleWindow,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> AXUIElement? {
        let axWindows: [EnumeratedWindow]
        if let cached = axCache[window.ownerPID] {
            axWindows = cached
        } else if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            axWindows = AXWindowEnumerator.windows(of: app)
            axCache[window.ownerPID] = axWindows
        } else {
            axCache[window.ownerPID] = []
            return nil
        }
        return axWindows.first(where: {
            Self.framesMatch($0.frame, window.frame, tolerance: 4)
        })?.axElement
    }

    /// Reads `kAXDocumentAttribute` and returns a POSIX file path if
    /// the attribute is present and parses as a file URL. Nil for apps
    /// that don't expose it (Messages, Discord, Notes' bespoke object
    /// model, Finder browser windows, etc.).
    private func resolveDocumentPath(
        for window: VisibleWindow,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> String? {
        guard let element = axElement(for: window, axCache: &axCache) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXDocumentAttribute as CFString,
            &value
        )
        guard result == .success, let str = value as? String else { return nil }
        if let url = URL(string: str), url.isFileURL {
            return url.path
        }
        return nil
    }

    /// Resolves the window's title via AX.
    private func resolveTitle(
        for window: VisibleWindow,
        axCache: inout [pid_t: [EnumeratedWindow]]
    ) -> String {
        guard let element = axElement(for: window, axCache: &axCache) else { return "" }
        var titleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard result == .success, let title = titleValue as? String else { return "" }
        return title
    }

    /// Builds a per-save context by pulling one cache-warm snapshot
    /// per unique browser bundleID in the selection. If the idle
    /// prefetch has run (typical case when saving after a lasso
    /// interaction), `snapshotBrowserWindows` returns immediately
    /// from cache. If cache is cold, one synchronous AppleScript
    /// fetch per bundleID runs here — still MUCH cheaper than one
    /// per selected window.
    private func buildBrowserSaveContext(
        for windows: [VisibleWindow]
    ) -> BrowserSaveCaptureContext {
        var context = BrowserSaveCaptureContext()
        var seenBundles: Set<String> = []
        for win in windows {
            guard let bundleID = NSRunningApplication(processIdentifier: win.ownerPID)?.bundleIdentifier,
                  BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { continue }
            if seenBundles.contains(bundleID) { continue }
            seenBundles.insert(bundleID)
            if let snapshots = BrowserScripting.snapshotBrowserWindows(bundleID: bundleID),
               !snapshots.isEmpty {
                context.snapshotsByBundleID[bundleID] = snapshots
                context.consumedInternalIDsByBundleID[bundleID] = []
            }
        }
        return context
    }

    /// Tries the per-save browser snapshot cache first (built by
    /// `buildBrowserSaveContext`). Matches `cocoaFrame` against
    /// unconsumed cached snapshots by frame center + size tolerance.
    /// Marks the matched snapshot consumed so no other selected
    /// window can double-book it.
    ///
    /// Falls back to the targeted per-window
    /// `snapshotBrowserWindowNearFrame` path (via
    /// `tabsForBrowserWindow`) only when: no cache entry for this
    /// bundle, no unconsumed match by frame, or the cache is stale
    /// (would need re-fetch anyway).
    private func tabsForBrowserWindowUsingCache(
        bundleID: String,
        cocoaFrame: CGRect,
        context: inout BrowserSaveCaptureContext
    ) -> [TabInfo]? {
        guard BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { return nil }
        let targetAX = CoordinateSpace.axRect(fromCocoa: cocoaFrame)
        // Try cache first.
        if let snapshots = context.snapshotsByBundleID[bundleID] {
            let consumed = context.consumedInternalIDsByBundleID[bundleID] ?? []
            // Rank unconsumed cached windows by frame distance from
            // target. Best match must be within tolerance to count.
            let matchTolerance: CGFloat = 30  // matches existing framesMatch tolerance
            var best: (snap: BrowserScripting.BrowserWindowSnapshot, distance: CGFloat)?
            for snap in snapshots where !consumed.contains(snap.internalID) {
                let dx = snap.boundsAX.midX - targetAX.midX
                let dy = snap.boundsAX.midY - targetAX.midY
                let dw = abs(snap.boundsAX.width  - targetAX.width)
                let dh = abs(snap.boundsAX.height - targetAX.height)
                // Only consider it a match if both center is close AND
                // sizes are close (rules out huge windows that happen
                // to sit near a small one's midpoint).
                let centerDist = (dx * dx + dy * dy).squareRoot()
                if centerDist < matchTolerance && dw < matchTolerance && dh < matchTolerance {
                    if best == nil || centerDist < best!.distance {
                        best = (snap, centerDist)
                    }
                }
            }
            if let match = best {
                var consumedSet = context.consumedInternalIDsByBundleID[bundleID] ?? []
                consumedSet.insert(match.snap.internalID)
                context.consumedInternalIDsByBundleID[bundleID] = consumedSet
                Log.corral.info(
                    "Browser save: prefetched snapshot used (bundle=\(bundleID, privacy: .public) window=\(match.snap.internalID, privacy: .public) tabs=\(match.snap.tabs.count, privacy: .public))"
                )
                return match.snap.tabs
            }
        }
        // Cache miss / no unconsumed match — fall back to targeted fetch.
        let reason = context.snapshotsByBundleID[bundleID] == nil ? "no cache" : "no match"
        Log.corral.info(
            "Browser save: targeted fallback used (bundle=\(bundleID, privacy: .public) reason=\(reason, privacy: .public))"
        )
        return tabsForBrowserWindow(bundleID: bundleID, cocoaFrame: cocoaFrame)
    }

    /// Returns tabs for the browser window whose bounds match
    /// `cocoaFrame` (targeted whose-filter → per-window fetch).
    /// Nil for non-browsers or when no window matches.
    private func tabsForBrowserWindow(
        bundleID: String,
        cocoaFrame: CGRect
    ) -> [TabInfo]? {
        guard BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { return nil }
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

    /// Generic informational alert for preflight failures. The event
    /// tap's window-frame exception routes clicks on this alert
    /// through to Cocoa even while lasso is on.
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
