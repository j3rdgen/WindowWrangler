//
//  CorralStore.swift
//  Window Wrangler
//
//  Persistence layer for the M8 Corral feature. Loads the corral list
//  from UserDefaults on init, persists on every mutation, and enforces
//  the MVP-scope cap of 5 corrals total.
//
//  Per CLAUDE.md's "modules stay separate" architecture, this is the
//  only place that knows how corrals are stored on disk. Everything
//  else (menu builder, save orchestrator, restore orchestrator) reads
//  and writes through this class.
//
//  UserDefaults is the right backing store for a prototype: no schema
//  migrations, no external file paths for a handoff developer to
//  chase, and a corral list of ≤5 entries is well under any size limit
//  UserDefaults imposes. A production build would revisit — for
//  instance, moving to an app-support-directory JSON file so the data
//  survives an app reinstall. That's parking-lot territory.
//

import Foundation
import os

@MainActor
final class CorralStore {

    /// MVP-scope hard cap. Enforced by `save(_:)`; UI surfaces this
    /// as "You have 5 groups. Delete one first." when a save is
    /// blocked.
    static let maxCorrals: Int = 5

    /// UserDefaults key. Scoped by the bundle's identifier prefix so
    /// two Window Wrangler builds (debug vs release) don't collide
    /// on the same machine.
    private static let userDefaultsKey: String = "com.jmw3.WindowWrangler.corrals.v1"

    /// The in-memory corral list. Ordered by insertion; the release
    /// menu displays them in the same order.
    private(set) var corrals: [Corral] = []

    /// Fires whenever the corral list changes — used by the menu
    /// builder to refresh the "Release ▸" submenu without needing to
    /// re-read from disk.
    var onChange: (() -> Void)?

    init() {
        load()
    }

    // MARK: - Load / persist

    /// Reads the corral list from UserDefaults. Called once at init
    /// and safe to call again (no other code writes to this key from
    /// outside `persist()`, but defensive re-loads don't hurt).
    ///
    /// A decode failure clears the list rather than crashing — the
    /// data is a prototype convenience, not something worth throwing
    /// on. Users can re-create corrals; keeping the app usable when
    /// the stored blob is malformed (e.g., after a model change in a
    /// dev build) is the right trade for a solo prototype.
    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else {
            corrals = []
            return
        }
        do {
            corrals = try JSONDecoder().decode([Corral].self, from: data)
            Log.corral.info(
                "Loaded \(self.corrals.count, privacy: .public) corral(s) from UserDefaults"
            )
        } catch {
            Log.corral.error(
                "Failed to decode corrals from UserDefaults: \(error.localizedDescription, privacy: .public) — starting empty"
            )
            corrals = []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(corrals)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            Log.corral.error(
                "Failed to encode corrals for UserDefaults: \(error.localizedDescription, privacy: .public)"
            )
        }
        onChange?()
    }

    // MARK: - Save (new / overwrite)

    /// Result of a save attempt. `.atCap` gives the caller a chance
    /// to show the user-facing "delete one first" message; `.saved`
    /// returns the (immutable) corral so the caller can update its
    /// own selection or logging.
    enum SaveResult {
        case saved(Corral)
        case atCap
    }

    /// Inserts a new corral. Returns `.atCap` if the store is already
    /// at the 5-corral limit; the caller should surface the message
    /// to the user rather than blocking silently.
    ///
    /// For the overwrite-in-place path (user answers "Replace" to the
    /// "Replace 'NAME'?" alert), callers use `overwrite(id:with:)`
    /// instead — that path skips the cap check because the total
    /// count isn't increasing.
    func save(_ corral: Corral) -> SaveResult {
        guard corrals.count < Self.maxCorrals else {
            Log.corral.notice(
                "Save blocked — at cap (\(Self.maxCorrals, privacy: .public))"
            )
            return .atCap
        }
        corrals.append(corral)
        persist()
        Log.corral.info(
            "Saved corral '\(corral.name, privacy: .public)' with \(corral.members.count, privacy: .public) member(s)"
        )
        return .saved(corral)
    }

    /// Replaces the corral with the given `id` in place. Used by the
    /// "Replace 'NAME'?" confirm flow — the user re-runs save with an
    /// existing name and the new snapshot supersedes the old one.
    /// Preserves the id and the original creation-order slot;
    /// bumps `capturedAt` to now via `Corral.withReplacedMembers`.
    func overwrite(id: UUID, with replacement: Corral) {
        guard let idx = corrals.firstIndex(where: { $0.id == id }) else {
            Log.corral.error(
                "Overwrite failed — no corral with id \(id.uuidString, privacy: .public)"
            )
            return
        }
        corrals[idx] = replacement
        persist()
        Log.corral.info(
            "Overwrote corral '\(replacement.name, privacy: .public)' with \(replacement.members.count, privacy: .public) member(s)"
        )
    }

    // MARK: - Delete / rename

    /// Removes the corral with the given id. No-op if not found.
    func delete(id: UUID) {
        let before = corrals.count
        corrals.removeAll { $0.id == id }
        guard corrals.count != before else { return }
        persist()
        Log.corral.info("Deleted corral id \(id.uuidString, privacy: .public)")
    }

    /// Renames the corral with the given id. No-op if not found.
    /// Doesn't validate the new name against collisions — that check
    /// belongs in the UI layer (rename prompt) since it needs to
    /// interact with the user.
    func rename(id: UUID, to newName: String) {
        guard let idx = corrals.firstIndex(where: { $0.id == id }) else {
            Log.corral.error(
                "Rename failed — no corral with id \(id.uuidString, privacy: .public)"
            )
            return
        }
        corrals[idx] = corrals[idx].withRenamed(newName)
        persist()
        Log.corral.info(
            "Renamed corral \(id.uuidString, privacy: .public) to '\(newName, privacy: .public)'"
        )
    }

    // MARK: - Lookup

    /// Case-insensitive lookup by exact name. Used by the save flow
    /// to decide whether to trigger the overwrite-confirm alert. A
    /// nil return means the name is free.
    func existingCorral(named name: String) -> Corral? {
        return corrals.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// True when a new save would be blocked. UI can use this to
    /// pre-emptively disable the save action or grey out the shortcut
    /// hint rather than let the user reach the pill and hit a wall.
    var isAtCap: Bool {
        return corrals.count >= Self.maxCorrals
    }
}
