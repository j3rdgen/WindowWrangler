//
//  OnboardingWindowController.swift
//  Window Wrangler
//
//  AppKit window shown when the user hasn't yet granted Accessibility
//  permission. Explains what the permission is, why we need it, and
//  provides a button to open System Settings directly to the right pane.
//
//  AppKit (not SwiftUI) by deliberate choice — keeps the launch path
//  free of SwiftUI scenes, and the window is simple enough that AppKit
//  is more direct. Preferences UI (later milestone) will use SwiftUI.
//

import AppKit

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user closes the window via the title-bar close
    /// button. Lets the app delegate clear its strong reference so the
    /// window can be re-created cleanly via "Reopen Setup…".
    var onWindowClosed: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppInfo.displayName) Setup"
        window.center()
        // Controller owns the window's lifetime; close just hides it.
        window.isReleasedWhenClosed = false
        // Float above other windows so the user sees it as the foreground
        // task even though the app is an .accessory (no Dock icon).
        window.level = .floating

        self.init(window: window)
        window.delegate = self
        window.contentViewController = OnboardingViewController()
    }

    /// Brings the window to the front. Since we're an .accessory app
    /// (no Dock icon), we have to explicitly activate to get focus.
    func presentOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}

// MARK: - Onboarding content

@MainActor
private final class OnboardingViewController: NSViewController {

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))

        // Big SF Symbol "hero" icon mirroring the menu bar glyph
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "rectangle.stack",
                                 accessibilityDescription: AppInfo.displayName)
        iconView.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        // Title
        let title = NSTextField(labelWithString:
            "\(AppInfo.displayName) needs Accessibility permission")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        // Body
        let bodyText = """
        \(AppInfo.displayName) arranges windows into staggered fan layouts. \
        To move other apps' windows, macOS requires you to grant the \
        "Accessibility" permission — the same permission used by apps \
        like Rectangle, Magnet, and BetterTouchTool.

        How to grant:
          1.  Click "Open Accessibility Settings" below.
          2.  Find \(AppInfo.displayName) in the list.
          3.  Toggle the switch ON.

        This window closes automatically once you've granted permission.
        """
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .systemFont(ofSize: 13)
        body.alignment = .left
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)

        // Primary button (Return key)
        let openButton = NSButton(title: "Open Accessibility Settings",
                                  target: self,
                                  action: #selector(openSettings))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(openButton)

        // Secondary button
        let quitButton = NSButton(title: "Quit \(AppInfo.displayName)",
                                  target: self,
                                  action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(quitButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            title.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),

            openButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            openButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            quitButton.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
            quitButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -12),
        ])

        view = container
    }

    @objc private func openSettings() {
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
