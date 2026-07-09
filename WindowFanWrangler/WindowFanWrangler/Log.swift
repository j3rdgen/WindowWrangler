//
//  Log.swift
//  Window Wrangler
//
//  Centralized `os.Logger` instances, one per concern. Categories let
//  Console.app filter to a specific subsystem ("show me cascade logs
//  only") and give us per-category severity filtering at runtime.
//
//  Why os.Logger instead of NSLog:
//   - Lazy evaluation: string interpolations aren't materialized when
//     the log level is below threshold (NSLog always pays the cost).
//   - Levels: .debug / .info / .notice / .error / .fault — Console
//     filters on these so noisy debug output doesn't drown signal.
//   - Faster: backed by the unified logging system (kernel-side
//     ring buffer) rather than stderr.
//   - Privacy: interpolated values can be marked .public when we
//     genuinely want them in logs (we do — these are diagnostic logs
//     for a single-user dev tool, not user-facing strings).
//
//  Subsystem = bundle ID so multiple Window Wrangler instances on the
//  same machine don't fight for the same log namespace.
//

import Foundation
import os

enum Log {

    /// Subsystem identifier for `os.Logger`. Uses the bundle ID so each
    /// product variant (debug build, release build, etc.) gets its own
    /// log namespace.
    private static let subsystem: String = {
        Bundle.main.bundleIdentifier ?? "com.jmw3.WindowWrangler"
    }()

    /// App lifecycle, launch, terminate, top-level events.
    static let app        = Logger(subsystem: subsystem, category: "app")

    /// AX framework I/O — enumeration, attribute reads, mutation.
    static let ax         = Logger(subsystem: subsystem, category: "ax")

    /// Cascade orchestration — passes, retries, verification, rescues.
    static let cascade    = Logger(subsystem: subsystem, category: "cascade")

    /// Lasso flow — drag begin/update/end, selection updates, overlay.
    static let lasso      = Logger(subsystem: subsystem, category: "lasso")

    /// Permission monitoring — AX trust polling, state transitions.
    static let permission = Logger(subsystem: subsystem, category: "permission")

    /// Global keyboard shortcuts.
    static let shortcuts  = Logger(subsystem: subsystem, category: "shortcuts")

    /// Window mutator — AX writes, readback discrepancies.
    static let mutator    = Logger(subsystem: subsystem, category: "mutator")

    /// Menu / status item / onboarding window.
    static let ui         = Logger(subsystem: subsystem, category: "ui")

    /// Corral feature — save/restore of named window workspaces.
    static let corral     = Logger(subsystem: subsystem, category: "corral")
}
