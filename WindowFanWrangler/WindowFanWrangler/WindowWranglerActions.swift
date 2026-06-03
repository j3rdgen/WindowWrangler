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
    @objc func restoreLayout()
    @objc func toggleLassoFromMenu()
    @objc func clearSelection()
    @objc func reopenOnboarding()
}
