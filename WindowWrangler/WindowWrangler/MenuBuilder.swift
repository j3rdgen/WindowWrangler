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
        /// Is Plot Mode currently active?
        let plotModeActive: Bool
        /// How many windows are in the current selection (0 hides the
        /// selection / clear-selection items).
        let selectionCount: Int
        /// Is there a `lastSnapshot` to restore? Drives the
        /// enable/disable state on the Restore item.
        let hasSnapshot: Bool
        /// Saved corrals, in insertion order. Populates the
        /// "Release ▸" submenu; empty list shows a grayed
        /// "No Saved Corrals" placeholder.
        let corrals: [Corral]
        /// True when the store is at its 5-corral cap. The Save item
        /// remains clickable — the orchestrator handles the cap alert
        /// itself — but we append a "(5/5)" hint to the title so the
        /// user knows before clicking.
        let corralsAtCap: Bool
        /// Whether the app is currently registered to launch at
        /// login. Drives the checkmark on the "Launch at Login" item.
        let launchAtLoginEnabled: Bool
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

        addPlotSection(
            to: menu,
            target: target,
            modifiers: shortcutModifiers,
            isTrusted: state.isTrusted,
            plotActive: state.plotModeActive
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

        menu.addItem(.separator())

        addCorralSection(
            to: menu,
            target: target,
            modifiers: shortcutModifiers,
            isTrusted: state.isTrusted,
            selectionCount: state.selectionCount,
            corrals: state.corrals,
            corralsAtCap: state.corralsAtCap
        )

        if !state.isTrusted {
            menu.addItem(.separator())
            addReopenSetupItem(to: menu, target: target)
        }

        menu.addItem(.separator())
        addLaunchAtLoginItem(to: menu, target: target, enabled: state.launchAtLoginEnabled)
        addDebugScanBrowserTabsItem(to: menu, target: target)
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

    /// Plot (Snap Window to Drawn Area) section. Same structural
    /// pattern as the Lasso section — a disabled state row plus a
    /// toggle row bound to the ⌃⌥⌘P shortcut. Independent of Lasso
    /// state; mode arbitration is handled by the coordinators.
    private static func addPlotSection(
        to menu: NSMenu,
        target: WindowWranglerActions,
        modifiers: NSEvent.ModifierFlags,
        isTrusted: Bool,
        plotActive: Bool
    ) {
        let stateItem = NSMenuItem(
            title: plotActive
                ? "Plot Mode: ● ON  — click a window, then drag its area"
                : "Plot Mode: Off",
            action: nil,
            keyEquivalent: ""
        )
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let toggleItem = NSMenuItem(
            title: plotActive
                ? "Turn Off Plot Mode"
                : "Plot (Snap Window to Drawn Area)",
            action: #selector(WindowWranglerActions.togglePlotFromMenu),
            keyEquivalent: "p"
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

        // All-apps cascade — uses the same modifier chord as single-app
        // (⌃⌥⌘) but with bracket keys. Bracket direction matches the
        // cascade direction visually: `[` → Down-Left, `]` → Down-Right.
        // Three-modifier brackets is unclaimed by macOS Tahoe.
        let cascadeAllAppsRight = NSMenuItem(
            title: "Cascade All Apps Down-Right",
            action: #selector(WindowWranglerActions.cascadeAllAppsDownRight),
            keyEquivalent: "]"  // ⌃⌥⌘]
        )
        cascadeAllAppsRight.keyEquivalentModifierMask = modifiers
        cascadeAllAppsRight.target = target
        cascadeAllAppsRight.isEnabled = isTrusted
        menu.addItem(cascadeAllAppsRight)

        let cascadeAllAppsLeft = NSMenuItem(
            title: "Cascade All Apps Down-Left",
            action: #selector(WindowWranglerActions.cascadeAllAppsDownLeft),
            keyEquivalent: "["  // ⌃⌥⌘[
        )
        cascadeAllAppsLeft.keyEquivalentModifierMask = modifiers
        cascadeAllAppsLeft.target = target
        cascadeAllAppsLeft.isEnabled = isTrusted
        menu.addItem(cascadeAllAppsLeft)

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

    /// Corral (Save + Release) section. Save is the top item; Release
    /// is a submenu containing one entry per saved corral (clicking
    /// restores that specific corral directly, no pill needed) plus a
    /// "Manage Corrals…" item at the bottom that opens the pill for
    /// delete / management.
    ///
    /// Save is enabled only when there's a lasso selection AND
    /// accessibility is granted — matches the ⌃⌥⌘S shortcut's
    /// preflight in CorralOrchestrator.beginSave.
    ///
    /// Release is always enabled when accessibility is granted (even
    /// with zero saved corrals, so users can still discover the "no
    /// saved corrals yet" empty-state message via the pill).
    private static func addCorralSection(
        to menu: NSMenu,
        target: WindowWranglerActions,
        modifiers: NSEvent.ModifierFlags,
        isTrusted: Bool,
        selectionCount: Int,
        corrals: [Corral],
        corralsAtCap: Bool
    ) {
        // Save — requires selection + not-at-cap for enabling
        // (orchestrator still handles the cap alert if user forces it).
        let saveTitle = corralsAtCap
            ? "Corral (Save Window Group) — (\(corrals.count)/\(CorralStore.maxCorrals) — delete one first)"
            : "Corral (Save Window Group)"
        let save = NSMenuItem(
            title: saveTitle,
            action: #selector(WindowWranglerActions.corralSave),
            keyEquivalent: "s"  // ⌃⌥⌘S
        )
        save.keyEquivalentModifierMask = modifiers
        save.target = target
        save.isEnabled = isTrusted && selectionCount > 0 && !corralsAtCap
        menu.addItem(save)

        // Release — submenu of saved corrals + "Manage…" pill entry.
        let release = NSMenuItem(
            title: "Release (Open Window Group)",
            action: nil,
            keyEquivalent: ""
        )
        release.isEnabled = isTrusted
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if corrals.isEmpty {
            let empty = NSMenuItem(
                title: "No Saved Corrals",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for corral in corrals {
                let item = NSMenuItem(
                    title: corral.name,
                    action: #selector(WindowWranglerActions.restoreCorralFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.isEnabled = isTrusted
                // Pass the UUID through so the action handler knows
                // which corral to restore — NSMenuItem targets are
                // Obj-C runtime dispatched and can't take typed args
                // directly, so representedObject is the standard
                // out-of-band channel.
                item.representedObject = corral.id
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Manage Corrals…",
            action: #selector(WindowWranglerActions.corralRelease),
            keyEquivalent: "r"  // ⌃⌥⌘R — opens the release pill (delete UI)
        )
        manage.keyEquivalentModifierMask = modifiers
        manage.target = target
        manage.isEnabled = isTrusted
        submenu.addItem(manage)

        release.submenu = submenu
        menu.addItem(release)
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

    private static func addLaunchAtLoginItem(
        to menu: NSMenu,
        target: WindowWranglerActions,
        enabled: Bool
    ) {
        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(WindowWranglerActions.toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = true
        // Use an SF-Symbol checkmark in the image slot instead of
        // NSMenuItem's state indicator. The state indicator column
        // sits ~24pt to the left of the text (macOS default reserved
        // width); an image renders flush against the text, matching
        // the visual grouping of Quit's icon in the same menu.
        if enabled {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            item.image = NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: "Launch at Login is on"
            )?.withSymbolConfiguration(config)
        }
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

    /// Tab X-Ray spike item (tab-duplicate-xray branch).
    /// Triggers a one-shot scan of running browsers and dumps the AX +
    /// AppleScript tab exposure to Console under subsystem
    /// `com.jmw3.WindowWrangler`, category `tabXray`.
    private static func addDebugScanBrowserTabsItem(
        to menu: NSMenu,
        target: WindowWranglerActions
    ) {
        let item = NSMenuItem(
            title: "Debug: Scan Browser Tabs → Console",
            action: #selector(WindowWranglerActions.debugScanBrowserTabs),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = true
        menu.addItem(item)
    }
}
