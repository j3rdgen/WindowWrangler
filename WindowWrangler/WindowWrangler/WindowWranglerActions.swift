//
//  WindowWranglerActions.swift
//  Window Wrangler
//
//  Protocol that fronts the AppDelegate's @objc menu-action methods.
//  Allows MenuBuilder to wire NSMenuItem actions without importing
//  the AppDelegate type directly, decoupling menu construction from
//  the AppDelegate.
//
//  The selectors named here MUST match the @objc method signatures
//  the AppDelegate exposes. NSMenuItem's target/action wiring is
//  Objective-C runtime based, so this protocol is `@objc` and the
//  conforming class is required to expose each method with the
//  exact signature.
//

import AppKit

@objc protocol WindowWranglerActions: AnyObject {
    @objc func cascadeDownRight()
    @objc func cascadeDownLeft()
    @objc func cascadeAllAppsDownRight()
    @objc func cascadeAllAppsDownLeft()
    @objc func restoreLayout()
    @objc func toggleLassoFromMenu()
    @objc func togglePlotFromMenu()
    @objc func clearSelection()
    @objc func reopenOnboarding()
    @objc func corralSave()
    @objc func corralRelease()
    /// Restores a specific corral directly from the menu bar
    /// "Release ▸" submenu. The sender's `representedObject` carries
    /// the corral's UUID (set by MenuBuilder at build time).
    @objc func restoreCorralFromMenu(_ sender: Any)
    /// Toggles the Login Item registration — the "Launch at Login"
    /// checkbox in the menu.
    @objc func toggleLaunchAtLogin()
    /// Tab X-Ray spike (tab-duplicate-xray branch) — scans running
    /// browser processes and logs their AX + AppleScript tab exposure
    /// to Console under subsystem `com.jmw3.WindowWrangler`,
    /// category `tabXray`. Investigation only; no UI side-effects.
    @objc func debugScanBrowserTabs()
    /// Tab Markers (tab-duplicate-xray branch) — toggles the colored
    /// duplicate-tab markers overlay on and off. Bound to ⌃⌥⌘X.
    @objc func toggleTabMarkers()
    /// Tab Markers (tab-duplicate-xray branch) — manually requests
    /// a fresh scan while the overlay is already active. Bound to
    /// ⌃⌥⌘⇧X and the floating pill's refresh button. No-op if the
    /// overlay is OFF.
    @objc func refreshTabMarkers()
    /// Phase A diagnostic (tab-duplicate-xray branch) — runs the
    /// three-strategy AppleScript benchmark against every running
    /// supported browser and logs timings to Console under
    /// subsystem com.jmw3.WindowWrangler category tabXray. Takes
    /// 3–15 seconds per invocation.
    @objc func debugBenchmarkAppleScript()
}
