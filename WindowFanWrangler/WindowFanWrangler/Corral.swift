//
//  Corral.swift
//  Window Wrangler
//
//  Data model for the M8 Corral feature — a Corral is a persistent,
//  user-named collection of windows that can be saved and restored as
//  a single workspace ("Research", "Meeting", "Deep-focus", …).
//
//  Everything here is a plain value type conforming to Codable so a
//  Corral survives an app relaunch via JSON in UserDefaults. No AX
//  calls, no side effects — pure model.
//
//  The Corral is app-agnostic: every member is described by its
//  bundle-ID + a title snapshot + the frame we want the window at.
//  For browser windows we ALSO record the tab list (URL + title per
//  tab); everything else has `tabs == nil` and restore just moves
//  the window back to `frame`. The `tabs` field lives on every
//  member so we don't need parallel per-app model types — it's
//  ignored by non-browser restore paths.
//
//  Coordinates are Cocoa (bottom-left global origin) so the value we
//  store is directly usable by `WindowMutator.setFrame`.
//

import Foundation
import CoreGraphics

// MARK: - Tabs

/// One browser tab captured at save time.
///
/// Both URL and title are kept: the URL is what we use to restore the
/// tab via the browser's scripting bridge, and the title is what we
/// show in "missing" messages ("couldn't restore 3 tabs from Chrome:
/// 'GitHub', 'Docs', 'Reddit'") when a restore can't find or open a
/// matching browser window.
struct TabInfo: Codable, Equatable {
    let url: String
    let title: String
}

// MARK: - Members

/// One window's snapshot within a Corral.
///
/// `windowTitle` is a hint — the title at save time. Titles are
/// mutable and don't reliably identify a window across app relaunches,
/// so restore uses it as a fuzzy match signal, not a strict key.
/// `tabs` is populated only for scriptable browser windows.
struct CorralMember: Codable, Equatable {
    /// e.g. "com.google.Chrome". Matched at restore time against
    /// running apps by `NSRunningApplication.bundleIdentifier`.
    let appBundleID: String
    /// e.g. "Google Chrome". Human-readable, shown in "missing"
    /// messages when the app isn't running at restore time.
    let appName: String
    /// Title snapshot at save time — a hint, not a key.
    let windowTitle: String
    /// Cocoa-coordinate frame the restore should return the window to.
    let frame: CGRect
    /// 0 = frontmost within this corral. Restore raises members in
    /// reverse of this index so slot 0 ends up on top of the stack
    /// (same pattern the cascade uses in `enforceCascadeZOrder`).
    let zOrderIndex: Int
    /// Browser tabs (URL + title per tab), in the browser's tab order.
    /// Non-nil only for scriptable-browser members. When present,
    /// restore uses these to either (a) match an existing browser
    /// window with the same URL set or (b) open a new browser window
    /// with these tabs if no match exists.
    let tabs: [TabInfo]?
}

// MARK: - Corral

/// A named, persistent workspace — the top-level object of M8.
///
/// The `id` is stable for the lifetime of the corral (survives
/// renames, replaces its members when overwritten). Callers that
/// need to refer to a specific corral over time (menu items,
/// restore-by-ID) hold the UUID, not the name.
struct Corral: Codable, Equatable, Identifiable {
    let id: UUID
    /// User-provided name, capped at 50 characters at input time.
    let name: String
    /// When this snapshot was captured. Shown as "Saved 3 days ago"
    /// in the release menu if useful; also lets us sort by recency.
    let capturedAt: Date
    /// Ordered members. Restore iterates in this same order to give
    /// deterministic behavior across runs.
    let members: [CorralMember]

    /// Fresh-corral initializer. Generates a new UUID and stamps
    /// `capturedAt = now`. Callers replacing an existing corral (the
    /// "Replace 'NAME'?" flow) use `withReplacedMembers(_:)` instead
    /// so the id is preserved.
    init(name: String, members: [CorralMember]) {
        self.id = UUID()
        self.name = name
        self.capturedAt = Date()
        self.members = members
    }

    /// Explicit-id initializer used by decoding and by
    /// `withReplacedMembers(_:)`. Kept `internal` so callers outside
    /// this file don't accidentally fabricate collisions.
    internal init(id: UUID, name: String, capturedAt: Date, members: [CorralMember]) {
        self.id = id
        self.name = name
        self.capturedAt = capturedAt
        self.members = members
    }

    /// Returns a new Corral with the same `id` and `name` but fresh
    /// `members` and a new `capturedAt`. This is the "overwrite in
    /// place" path — invoked when the user says "Replace 'NAME'"
    /// in the save flow.
    func withReplacedMembers(_ newMembers: [CorralMember]) -> Corral {
        return Corral(
            id: id,
            name: name,
            capturedAt: Date(),
            members: newMembers
        )
    }

    /// Returns a new Corral with the same `id`, `capturedAt`, and
    /// `members`, but a new `name`. For future rename UI.
    func withRenamed(_ newName: String) -> Corral {
        return Corral(
            id: id,
            name: newName,
            capturedAt: capturedAt,
            members: members
        )
    }
}
