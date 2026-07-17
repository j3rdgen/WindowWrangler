//
//  CorralToast.swift
//  Window Wrangler
//
//  Brief centered confirmation pill shown after a successful Corral
//  save (and, in M8.3, after a successful restore). Same visual
//  family as LassoModeHint and CorralNamePill — dark translucent
//  capsule — with a green checkmark glyph and the saved name so
//  the user has an immediate, unambiguous "done" signal.
//
//  Auto-dismiss: fade in ~150ms, hold ~1.4s, fade out ~250ms. Total
//  visible time ≈ 1.8s. Non-interactive (`ignoresMouseEvents = true`)
//  so it can never block a click on whatever's underneath, and
//  positioned mid-screen where the name pill was — so the user's
//  eye is already looking there when it appears.
//

import AppKit

@MainActor
final class CorralToast {

    /// Visual style — "in progress" (neutral dark) or "success" (green).
    /// Progress toasts don't auto-dismiss; the caller must swap them
    /// out with `showSaved` (or dismiss them explicitly) once the work
    /// they're announcing has finished.
    enum Style {
        case progress
        case success

        var backgroundColor: NSColor {
            switch self {
            case .progress:
                return NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.18, alpha: 0.90)
            case .success:
                return NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.30, alpha: 0.92)
            }
        }
    }

    private var panel: NSPanel?

    /// Shows a persistent "Saving…" (or similar) toast that stays on
    /// screen until dismissed. Use for long-running work where the
    /// synchronous main-runloop block would otherwise leave the user
    /// with no visible feedback between the pill closing and the
    /// success toast appearing.
    func showProgress(text: String) {
        present(text: text, style: .progress, autoDismiss: nil, onDismiss: nil)
    }

    /// Immediately removes any visible toast without a fade or an
    /// onDismiss callback. Called by the orchestrator right before
    /// showing the success toast so the two don't overlap on screen.
    func dismissNow() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Shows the toast for the given saved-corral name. Fires
    /// `onDismiss` after the fade-out completes so the caller can
    /// release its reference. Idempotent per instance — calling
    /// again while a previous toast is still on-screen tears the
    /// old one down and starts fresh.
    func showSaved(name: String, onDismiss: @escaping () -> Void) {
        present(
            text: "✓  Saved '\(name)'",
            style: .success,
            autoDismiss: 1.4,
            onDismiss: onDismiss
        )
    }

    /// Internal presenter used by both progress and success toasts.
    /// Extracted so the two paths share the panel-construction and
    /// positioning code and only differ in color / auto-dismiss.
    private func present(
        text: String,
        style: Style,
        autoDismiss: TimeInterval?,
        onDismiss: (() -> Void)?
    ) {
        panel?.orderOut(nil)
        panel = nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let hPad: CGFloat = 22
        let vPad: CGFloat = 12
        let contentSize = NSSize(
            width: label.frame.width + 2 * hPad,
            height: label.frame.height + 2 * vPad
        )
        let contentFrame = NSRect(origin: .zero, size: contentSize)

        let bg = NSView(frame: contentFrame)
        bg.wantsLayer = true
        if let layer = bg.layer {
            // Color varies by style — green for success (unmistakable
            // "done" signal), neutral dark for progress (matches the
            // LassoModeHint / name pill family so it reads as
            // "in-flight state").
            layer.backgroundColor = style.backgroundColor.cgColor
            layer.cornerRadius = contentSize.height / 2
            layer.masksToBounds = true
        }
        label.frame = NSRect(
            x: hPad,
            y: vPad,
            width: label.frame.width,
            height: label.frame.height
        )
        bg.addSubview(label)

        let panel = NSPanel(
            contentRect: contentFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.floating.rawValue + 1
        )
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
        ]
        panel.sharingType = .none
        panel.contentView = bg

        positionAtCenter(panel: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        // Fade in.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // Fade out after a brief hold — only for auto-dismissing
        // toasts (i.e. success). Progress toasts stay on-screen until
        // the caller explicitly dismisses them.
        if let holdSeconds = autoDismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) { [weak self, weak panel] in
                guard let panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self, weak panel] in
                    panel?.orderOut(nil)
                    self?.panel = nil
                    onDismiss?()
                })
            }
        }
    }

    /// Positions the pill mid-screen, matching the vertical placement
    /// used by `CorralNamePill.positionAtCenter` so the toast appears
    /// exactly where the pill just was — the user's eye is already
    /// there.
    private func positionAtCenter(panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
