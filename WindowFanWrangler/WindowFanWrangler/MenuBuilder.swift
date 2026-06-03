//
//  MenuBuilder.swift
//  Window Wrangler
//
//  Pure NSMenu construction from a snapshot of current state. Lifted
//  out of AppDelegate so the menu's shape is testable in isolation
//  and AppDelegate doesn't have to grow each time a menu item is
//  added.
//
//  Stateless by design: every call to `build(state:target:)` returns
//  a fresh NSMenu reflecting `state`. The caller (AppDelegate) is
//  responsible for assigning it to the NSStatusItem.
//

import AppKit

@MainActor
enum MenuBuilder {

    /// Read-only snapshot of every input that affects the menu's
    /// shape. Computed by the AppDelegate at rebuild time.
    struct State {
        /// Has the user granted Accessibility permission?
        let isTrusted: Bool
        /// Is lasso mode currently active?
        let lassoModeActive: Bool
        /// How many windows are in the current selection (0 hides the
        /// selection / clear-selection items).
        let selectionCount: Int
        /// Is there a `lastSnapshot` to restore? Drives the
        /// enable/disable state on the Restore item.
        let hasSnapshot: Bool
    }

    /// Builds a fresh NSMenu reflecting `state`. Menu items are wired
    /// to call `target`'s WindowWranglerActions methods.
    static func build(state: State, target: WindowWranglerActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Shared modifier mask for all our shortcut hints in this menu.
        // These keyEquivalents are purely for visual display in the menu;
        // the actual firing is handled by GlobalShortcuts (since we're an
        // accessory app and macOS won't fire menu shortcuts when we're
        // not frontmost).
        let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

        addPermissionHeader(to: menu, isTrusted: state.isTrusted)
        menu.addItem(.separator())

        addLassoSection(
            to: menu,
            target: target,
            modifiers: shortcutModifiers,
            isTrusted: state.isTrusted,
            lassoActive: state.lassoModeActive
        )

        if state.selectionCount > 0 {
            addSelectionSection(
                to: menu,
                target: target,
                selectionCount: state.selectionCount
            )
        }

        menu.addItem(.separator())

        addCascadeAndRestoreSection(
            to: menu,
            target: target,
            modifiers: shortcutModifiers,
            isTrusted: state.isTrusted,
            hasSnapshot: state.hasSnapshot
        )

        if !state.isTrusted {
            menu.addItem(.separator())
            addReopenSetupItem(to: menu, target: target)
        }

        menu.addItem(.separator())
        addQuitItem(to: menu)

        return menu
    }

    // MARK: - Sections

    private static func addPermissionHeader(to menu: NSMenu, isTrusted: Bool) {
        let header = NSMenuItem(
            title: isTrusted
                ? "Accessibility: ✓ Granted"
                : "Accessibility: ⚠︎ Not granted",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
    }

    private static func addLassoSection(
        to menu: NSMenu,
        target: WindowWranglerActions,
        modifiers: NSEvent.ModifierFlags,
        isTrusted: Bool,
        lassoActive: Bool
    ) {
        let stateItem = NSMenuItem(
            title: lassoActive
                ? "Lasso Mode: ● ON  — click-drag to select"
                : "Lasso Mode: Off",
            action: nil,
            keyEquivalent: ""
        )
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let toggleItem = NSMenuItem(
            title: lassoActive ? "Turn Off Lasso Mode" : "Turn On Lasso Mode",
            action: #selector(WindowWranglerActions.toggleLassoFromMenu),
            keyEquivalent: "c"
        )
        toggleItem.keyEquivalentModifierMask = modifiers
        toggleItem.target = target
        toggleItem.isEnabled = isTrusted
        menu.addItem(toggleItem)
    }

    private static func addSelectionSection(
        to menu: NSMenu,
        target: WindowWranglerActions,
        selectionCount: Int
    ) {
        let plural = selectionCount == 1 ? "" : "s"
        let header = NSMenuItem(
            title: "Selection: \(selectionCount) window\(plural)",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        let clearItem = NSMenuItem(
            title: "Clear Selection",
            action: #selector(WindowWranglerActions.clearSelection),
            keyEquivalent: ""
        )
        clearItem.target = target
        clearItem.isEnabled = true
        menu.addItem(clearItem)
    }

    private static func addCascadeAndRestoreSection(
        to menu: NSMenu,
        target: WindowWranglerActions,
        modifiers: NSEvent.ModifierFlags,
        isTrusted: Bool,
        hasSnapshot: Bool
    ) {
        let cascadeRight = NSMenuItem(
            title: "Cascade Down-Right",
            action: #selector(WindowWranglerActions.cascadeDownRight),
            keyEquivalent: "."  // ⌃⌥⌘.
        )
        cascadeRight.keyEquivalentModifierMask = modifiers
        cascadeRight.target = target
        cascadeRight.isEnabled = isTrusted
        menu.addItem(cascadeRight)

        let cascadeLeft = NSMenuItem(
            title: "Cascade Down-Left",
            action: #selector(WindowWranglerActions.cascadeDownLeft),
            keyEquivalent: ","  // ⌃⌥⌘,
        )
        cascadeLeft.keyEquivalentModifierMask = modifiers
        cascadeLeft.target = target
        cascadeLeft.isEnabled = isTrusted
        menu.addItem(cascadeLeft)

        let restore = NSMenuItem(
            title: "Restore Previous Layout",
            action: #selector(WindowWranglerActions.restoreLayout),
            keyEquivalent: "\u{F700}"  // NSUpArrowFunctionKey
        )
        restore.keyEquivalentModifierMask = modifiers
        restore.target = target
        // Enabled only when we have AX permission AND a snapshot to restore.
        restore.isEnabled = isTrusted && hasSnapshot
        menu.addItem(restore)
    }

    private static func addReopenSetupItem(to menu: NSMenu, target: WindowWranglerActions) {
        let item = NSMenuItem(
            title: "Reopen Setup…",
            action: #selector(WindowWranglerActions.reopenOnboarding),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = true
        menu.addItem(item)
    }

    private static func addQuitItem(to menu: NSMenu) {
        let item = NSMenuItem(
            title: "Quit \(AppInfo.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.isEnabled = true
        menu.addItem(item)
    }
}
