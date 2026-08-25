//
//  PlotModeHint.swift
//  Window Wrangler
//
//  Floating "Press Esc to End Plot Mode" pill shown while Plot mode
//  is active. Mirrors LassoModeHint (same panel style, same collection
//  behavior, same top-center placement, same mouse-transparent panel)
//  so the two mode hints read as a single visual system.
//
//  The pill text is EXACTLY "Press Esc to End Plot Mode" for the
//  entire duration of Plot mode. It never changes to reflect
//  awaitingWindow / windowSelected / drawingPlot state.
//

import AppKit

@MainActor
final class PlotModeHint {

    private var panel: NSPanel?

    private let hintText = "Press Esc to End Plot Mode"

    /// Alpha the pill fades to when Plot has passed the initial
    /// selection state. Low enough that the underlying screen
    /// content is easy to read through it, but not so low that
    /// the "Press Esc to End Plot Mode" reminder disappears.
    private let dimmedAlpha: CGFloat = 0.28

    // MARK: - Public API

    func show() {
        let p = panel ?? makePanel()
        positionAtTopCenter(panel: p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    /// Fades the pill to a low-opacity state so it stops visually
    /// obscuring screen area near the top of the display once the
    /// user has selected a target. The Esc reminder stays readable
    /// but the pill's dark capsule no longer blocks the user's view
    /// of the windows they're about to draw a Plot Area over.
    func dim() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = dimmedAlpha
        }
    }

    /// Restores the pill to full opacity. Called when Plot returns
    /// to `awaitingWindow` after a successful placement, so the
    /// mode reminder becomes clearly visible again while the user
    /// picks the next target.
    func undim() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    /// Immediate teardown with no fade. Used on Escape or hard
    /// mode-arbitration teardown where a delayed fade could let a
    /// stale animation reveal a pill after Plot has ended.
    func hideImmediately() {
        guard let p = panel else { return }
        p.orderOut(nil)
        p.alphaValue = 0
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let label = NSTextField(labelWithString: hintText)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let hPad: CGFloat = 18
        let vPad: CGFloat = 9
        let contentSize = NSSize(
            width: label.frame.width + 2 * hPad,
            height: label.frame.height + 2 * vPad
        )
        let frame = NSRect(origin: .zero, size: contentSize)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        // Same level as LassoModeHint so both mode pills render at
        // the same z-index vs the SelectionOverlay panels.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.hidesOnDeactivate = false
        p.collectionBehavior = [
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
        ]
        p.sharingType = .none

        let bg = NSView(frame: frame)
        bg.wantsLayer = true
        if let layer = bg.layer {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
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
        p.contentView = bg
        return p
    }

    // MARK: - Positioning

    private func positionAtTopCenter(panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Screen the user is most likely looking at — cursor's display,
    /// falling back to main / first screen. Mirrors LassoModeHint.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
