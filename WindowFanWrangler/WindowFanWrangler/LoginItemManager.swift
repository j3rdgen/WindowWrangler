//
//  LoginItemManager.swift
//  Window Wrangler
//
//  Thin wrapper around `SMAppService.mainApp` (macOS 13+ Login Items
//  API). Registers Window Wrangler to auto-launch when the user logs
//  in, so a menu-bar utility they installed once is silently there
//  on every reboot without them having to remember Spotlight-launch it.
//
//  Managed via System Settings > General > Login Items & Extensions —
//  users can also revoke there. We read the current registration state
//  live rather than caching it, so the menu's checkmark reflects
//  reality even if the user toggled it in System Settings.
//

import Foundation
import ServiceManagement
import os

@MainActor
enum LoginItemManager {

    /// True if the app is currently registered to launch at login.
    /// Reads live from `SMAppService`, no cache — so a toggle done in
    /// System Settings > Login Items is reflected next time the menu
    /// rebuilds.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a Login Item. Failures
    /// (user denial, service unavailable) are logged; the caller can
    /// re-check `isEnabled` after to see the actual outcome.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
                Log.app.notice("Login item registered — will auto-launch at login")
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
                Log.app.notice("Login item unregistered — will not auto-launch")
            }
        } catch {
            Log.app.error(
                "Login item toggle failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
