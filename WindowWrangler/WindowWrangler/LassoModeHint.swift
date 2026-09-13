//
//  LassoModeHint.swift
//  Window Wrangler
//
//  Floating "Press Esc to end Lasso mode" pill shown while lasso
//  mode is active. Positioned at the top-center of whichever screen
//  the cursor is on — same convention macOS itself uses for the
//  screenshot / screen-recording instruction strip, so it reads as
//  a system-level "you're in a mode" hint rather than app chrome.
//
//  Why not draw inside the SelectionOverlay panel:
//  the overlay is dynamically sized to the bounding box of the
//  current selection + lasso rect. While dragging, that box is
//  often tiny or empty, so a hint embedded in it would be clipped
//  or invisible. A dedicated panel keeps the hint visible the
//  entire time lasso mode is on, regardless of selection state.
//
//  Mouse events pass through (ignoresMouseEvents = true) so the
//  hint never interferes with the lasso drag itself.
//

import AppKit

@MainActor
final class LassoModeHint {

    private var panel: NSPanel?

    private let hintText = "Press Esc to End Lasso Mode"

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

    func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
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

        // Padding around the text. The pill's corner radius is half
        // the resulting height — so it reads as a clean capsule.
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
        // Sit ABOVE the SelectionOverlay panel (which is .floating).
        // SelectionOverlay calls orderFrontRegardless() continuously
        // during a drag, so if they share the same level the dashed
        // selection borders end up rendered on top of the hint. Using
        // a higher level guarantees the pill always stays on top of
        // the lasso/selection rendering.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.hidesOnDeactivate = false
        // Same collection-behavior set as SelectionOverlay so the hint
        // doesn't slide between Spaces, doesn't show in Cmd-Tab, and
        // coexists peacefully with full-screen apps.
        p.collectionBehavior = [
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
        ]
        p.sharingType = .readOnly

        // Background: dark translucent capsule.
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
        // 16pt below the top of the usable area (just under the menu bar).
        let y = visible.maxY - size.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Returns the screen the user is most likely looking at — the one
    /// containing the cursor — falling back to the main / first screen.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
