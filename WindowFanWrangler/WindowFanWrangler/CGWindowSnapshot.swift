//
//  CGWindowSnapshot.swift
//  Window Wrangler
//
//  Cheap, non-authoritative CG snapshot used as a NEGATIVE prefilter
//  for the All-Apps Cascade enumeration path. Answers ONE question:
//  "which PIDs own at least one plausible on-screen window right now?"
//
//  CRITICAL SEMANTICS
//  -------------------
//  `CGWindowListCopyWindowInfo` returns nil ONLY on API failure — a
//  running WindowServer with zero windows returns a valid empty array.
//  This module preserves that distinction as a two-case result type:
//
//      .success(pidsWithAnyWindow: Set<pid_t>)   ← authoritative empty possible
//      .failure                                  ← call itself failed
//
//  The distinction matters because the All-Apps Cascade uses a
//  CG-negative accessory prefilter ONLY when the snapshot succeeded
//  (fail-open on `.failure` — enumerate every accessory app via AX).
//  `CrossAppWindowEnumerator.allVisibleWindows()` collapses both cases
//  to `[]` and is therefore unsafe as a hard negative filter; that
//  abstraction stays untouched for Lasso/Plot/Corral use where the
//  distinction doesn't matter.
//
//  This module is DELIBERATELY MORE PERMISSIVE than allVisibleWindows():
//  no layer / size / alpha / owner blocklist filtering. The only job is
//  to answer "does this PID have any plausible user window at all?" —
//  AX remains authoritative for final Cascade eligibility. Overfiltering
//  here would risk skipping an accessory app that owns a legitimate
//  window CG happens to represent with an unusual layer or size.
//

import CoreGraphics
import Foundation

/// Result of one CG window-list snapshot. The two cases are mutually
/// exclusive; the presence of `.failure` distinguishes "CG API is
/// unavailable / errored" from "CG API succeeded with an empty list".
enum CGWindowSnapshot {
    /// CG returned a valid (possibly empty) window list. The set holds
    /// every distinct owning PID observed in the on-screen window
    /// list — a PID's presence here means "AX enumeration might matter",
    /// its absence on a successful snapshot means "no on-screen CG
    /// evidence of any window for this PID".
    case success(pidsWithAnyWindow: Set<pid_t>)
    /// `CGWindowListCopyWindowInfo` returned nil, or its result was
    /// not the expected shape. Callers MUST treat this as unknown
    /// state and fail open (do not skip anything).
    case failure

    /// Convenience for callers that want a plain PID set with an
    /// explicit "was the snapshot successful" bit.
    var pids: Set<pid_t>? {
        switch self {
        case .success(let pids): return pids
        case .failure: return nil
        }
    }
}

enum CGWindowSnapshotter {

    /// Takes one CG snapshot of on-screen windows and returns the set
    /// of owning PIDs, distinguishing failure from empty success.
    ///
    /// Options match `CrossAppWindowEnumerator.allVisibleWindows()`
    /// for consistency (`.optionOnScreenOnly + .excludeDesktopElements`)
    /// but this call deliberately does NOT apply the subsequent
    /// filtering (layer/size/alpha/owner). Every PID with any raw CG
    /// entry lands in the candidate set — AX later decides whether the
    /// windows the app owns are actually cascade-eligible.
    ///
    /// Own-PID exclusion: not applied here. Window Wrangler itself is
    /// filtered by the caller (myBundle check in the eligibility filter)
    /// before we even look up its PID in this set; including it costs
    /// nothing.
    ///
    /// Expected cost: low single-digit milliseconds even on a system
    /// with hundreds of windows. Safe to call once per All-Apps Cascade
    /// planning operation.
    ///
    /// - Returns: `.success(pidsWithAnyWindow:)` on any successful
    ///   CG API call — including one that returns an empty list.
    ///   `.failure` iff `CGWindowListCopyWindowInfo` returned nil or a
    ///   result that could not be cast to the expected shape.
    static func snapshot() -> CGWindowSnapshot {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        // The double-cast pattern preserves the "nil ⇒ API failure"
        // distinction — if the CFArray -> NSArray -> Swift array bridge
        // fails, we treat it as failure rather than empty success.
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return .failure
        }

        var pids = Set<pid_t>()
        pids.reserveCapacity(raw.count)
        for dict in raw {
            if let pid = dict[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }
        return .success(pidsWithAnyWindow: pids)
    }
}
