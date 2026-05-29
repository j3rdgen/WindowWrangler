//
//  WindowWranglerApp.swift
//  Window Wrangler
//
//  Created by John Wilson on 5/26/26.
//
//  Milestone 2: menu-bar-only entry point.
//  Uses AppKit (NSApplicationDelegate + NSStatusItem) per CLAUDE.md —
//  SwiftUI's MenuBarExtra has known bugs and is avoided.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Manual entry point. With `@main` on an NSObject subclass, Swift looks
    /// for a `static func main()`. We wire up NSApplication ourselves rather
    /// than going through SwiftUI's App protocol.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Strong reference so the status item isn't deallocated.
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist's LSUIElement: ensure this app
        // runs as a menu-bar-only "accessory" — no Dock icon, no app menus.
        NSApp.setActivationPolicy(.accessory)

        // Create the menu bar slot. .variableLength sizes to the icon's width.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // SF Symbol; isTemplate=true lets macOS recolor for light/dark menu bars.
            let icon = NSImage(systemSymbolName: "rectangle.stack",
                               accessibilityDescription: "Window Wrangler")
            icon?.isTemplate = true
            button.image = icon
        }

        statusItem.menu = buildMenu()
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let fanItem = NSMenuItem(title: "Fan Windows",
                                 action: #selector(fanWindows),
                                 keyEquivalent: "")
        fanItem.target = self
        menu.addItem(fanItem)

        let restoreItem = NSMenuItem(title: "Restore Previous Layout",
                                     action: #selector(restoreLayout),
                                     keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        // Quit: target=nil lets the responder chain route to NSApp.
        menu.addItem(NSMenuItem(title: "Quit Window Wrangler",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        return menu
    }

    // MARK: - Placeholder actions (real implementations land in later milestones)

    @objc private func fanWindows() {
        NSLog("[Window Wrangler] Fan Windows clicked — not implemented yet")
    }

    @objc private func restoreLayout() {
        NSLog("[Window Wrangler] Restore Previous Layout clicked — not implemented yet")
    }
}
