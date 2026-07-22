//
//  CorralPanelHelpers.swift
//  Window Wrangler
//
//  Shared UI helpers used by the three Corral modal panels
//  (CorralNamePill, CorralReleaseMenu, CorralToast). Each of them
//  previously duplicated an `activeScreen`/`positionAtCenter` pair,
//  an `NSPanel` subclass that overrides `canBecomeKey`, and a
//  `@objc` closure-bridge for NSButton target/action.
//

import AppKit

/// Positions a panel horizontally centered, slightly above vertical
/// center on the display containing the mouse cursor. The 8% upward
/// nudge matches macOS's own "type to search" affordance — dead
/// center reads too low.
@MainActor
func centerCorralPanel(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    guard let screen = CoordinateSpace.screen(containing: mouse) else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let x = visible.midX - size.width / 2
    let y = visible.midY - size.height / 2 + visible.height * 0.08
    panel.setFrameOrigin(NSPoint(x: x, y: y))
}

/// NSPanel subclass with `.borderless` style that still accepts
/// keyboard focus — required so text fields and local key monitors
/// inside can observe keystrokes when `makeKeyAndOrderFront` is
/// called. `canBecomeMain` overridden for belt-and-suspenders.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// `@objc` bridge for NSButton target/action → Swift closure. Keeps
/// the closure alive for the button's lifetime and dispatches on
/// click. Callers hold the target so it isn't deallocated while the
/// button is on-screen.
final class ButtonTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any) { action() }
}
