//
//  LayoutSnapshot.swift
//  Window Wrangler
//
//  Captures a "before cascade" record of which AX window was at which
//  Cocoa-coordinate frame, so the user can hit "Restore Previous Layout"
//  and put everything back.
//
//  Held in memory only by the AppDelegate between fan and restore calls.
//  No persistence across app launches in M4 (could be added later if
//  we want).
//

import Foundation
import ApplicationServices

struct LayoutSnapshot {

    /// One window's pre-cascade state.
    struct Entry {
        let axElement: AXUIElement
        /// Original Cocoa-coordinate frame.
        let frame: CGRect
    }

    /// Window entries, in the same order they were enumerated.
    let entries: [Entry]

    /// When the snapshot was taken.
    let capturedAt: Date

    init(entries: [Entry]) {
        self.entries = entries
        self.capturedAt = Date()
    }

    /// Convenience constructor from a list of EnumeratedWindow.
    init(from enumerated: [EnumeratedWindow]) {
        self.entries = enumerated.map { Entry(axElement: $0.axElement, frame: $0.frame) }
        self.capturedAt = Date()
    }

    /// True if the snapshot has nothing to restore.
    var isEmpty: Bool { entries.isEmpty }
}
