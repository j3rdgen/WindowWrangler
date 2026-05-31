//
//  WindowWranglerApp.swift
//  Window Wrangler
//
//  Created by John Wilson on 5/26/26.
//
//  Menu-bar-only entry point + permission-state-aware menu and
//  onboarding integration.
//
//  Uses AppKit (NSApplicationDelegate + NSStatusItem) per CLAUDE.md —
//  SwiftUI's MenuBarExtra has known bugs and is avoided.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Manual entry point. With `@main` on an NSObject subclass, Swift
    /// looks for a `static func main()`. We wire up NSApplication
    /// ourselves rather than going through SwiftUI's App protocol.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - State

    /// Strong reference so the menu bar slot isn't deallocated.
    private var statusItem: NSStatusItem!

    /// Wrapper around AX permission API. Polls for state changes.
    private let permission = AccessibilityPermission()

    /// Onboarding window, kept alive while it's open.
    private var onboardingWindow: OnboardingWindowController?

    /// Last-known permission state. Used to build the menu synchronously
    /// and to detect just-granted/just-revoked transitions.
    private var isTrusted: Bool = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist's LSUIElement: ensure this
        // app runs as a menu-bar-only "accessory" — no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        startPermissionMonitoring()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = MenuBarIcon.image()
            icon.accessibilityDescription = AppInfo.displayName
            button.image = icon
        }

        rebuildMenu()
    }

    // MARK: - Permission monitoring

    /// Begins polling the AX permission state. The callback fires once
    /// immediately with the current value, then again only on changes.
    private func startPermissionMonitoring() {
        permission.startPolling { [weak self] granted in
            guard let self else { return }
            let wasTrusted = self.isTrusted
            self.isTrusted = granted
            self.rebuildMenu()

            if !granted && self.onboardingWindow == nil {
                // App just launched without permission, or permission was
                // revoked while the onboarding window was already closed.
                self.showOnboarding()
            } else if granted && !wasTrusted {
                // User just granted permission — close the explainer.
                self.dismissOnboarding()
            }
        }
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController()
        controller.onWindowClosed = { [weak self] in
            self?.onboardingWindow = nil
        }
        onboardingWindow = controller
        controller.presentOnboarding()
    }

    private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        // Drive enabled-state from our own flags, not the responder chain.
        menu.autoenablesItems = false

        // Permission status header — read-only indicator
        let header = NSMenuItem(
            title: isTrusted
                ? "Accessibility: ✓ Granted"
                : "Accessibility: ⚠︎ Not granted",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Fan / Restore — disabled until permission is granted
        let fanItem = NSMenuItem(title: "Fan Windows",
                                 action: #selector(fanWindows),
                                 keyEquivalent: "")
        fanItem.target = self
        fanItem.isEnabled = isTrusted
        menu.addItem(fanItem)

        let restoreItem = NSMenuItem(title: "Restore Previous Layout",
                                     action: #selector(restoreLayout),
                                     keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = isTrusted
        menu.addItem(restoreItem)

        // "Reopen Setup…" only when permission is missing
        if !isTrusted {
            menu.addItem(.separator())
            let reopenItem = NSMenuItem(title: "Reopen Setup…",
                                        action: #selector(reopenOnboarding),
                                        keyEquivalent: "")
            reopenItem.target = self
            reopenItem.isEnabled = true
            menu.addItem(reopenItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(AppInfo.displayName)",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Actions (real implementations land in later milestones)

    @objc private func fanWindows() {
        NSLog("[\(AppInfo.displayName)] Fan Windows clicked — not implemented yet")
    }

    @objc private func restoreLayout() {
        NSLog("[\(AppInfo.displayName)] Restore Previous Layout clicked — not implemented yet")
    }

    @objc private func reopenOnboarding() {
        if let existing = onboardingWindow {
            existing.presentOnboarding()
        } else {
            showOnboarding()
        }
    }
}
