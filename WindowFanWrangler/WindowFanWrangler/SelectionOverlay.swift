//
//  SelectionOverlay.swift
//  Window Wrangler
//
//  Transparent overlay PANEL that draws the lasso rubber-band rectangle
//  during an active drag and the highlight borders around currently-
//  selected windows.
//
//  Critical design choice: the panel is dynamically resized to JUST the
//  bounding box of the active content (lasso rect + selection frames),
//  plus a small padding for the stroke. It is NEVER full-screen.
//
//  Earlier full-screen overlay implementations caused both Chrome and
//  TextEdit to visually disappear because macOS's window-occlusion
//  detection sees a covering panel — even a transparent one — and many
//  apps pause their rendering pipeline when fully covered. By limiting
//  the panel to just the necessary area, the underlying apps remain
//  visible everywhere except where our highlight border literally is.
//
//  NSPanel + .nonactivatingPanel is still used for the same reason it
//  was tried before: it tells macOS this is a transient utility window
//  that doesn't take focus or trigger app-activation behaviors.
//

import AppKit

@MainActor
final class SelectionOverlay {

    // MARK: - State

    private var panel: NSPanel?
    private var view: OverlayView?

    /// Most recent lasso rectangle in Cocoa global coordinates.
    /// nil while no drag is active.
    private var currentLassoRect: CGRect?

    /// Frames of currently-selected windows in Cocoa global coordinates.
    private var selectionFrames: [CGRect] = []

    // MARK: - Public API

    /// No-op (kept for source compatibility with LassoCoordinator).
    /// The panel is created lazily by `updateWindow()` when there is
    /// actual content to show.
    func ensureWindow() { }

    func showLassoRect(_ rect: CGRect) {
        currentLassoRect = rect
        updateWindow()
    }

    func hideLassoRect() {
        currentLassoRect = nil
        updateWindow()
    }

    func setSelectionFrames(_ frames: [CGRect]) {
        selectionFrames = frames
        updateWindow()
    }

    /// No-op (kept for source compatibility). `updateWindow()` handles
    /// hiding internally when content is empty.
    func hideIfEmpty() { }

    // MARK: - Window lifecycle

    /// Recomputes the bounding box of all visible content, resizes the
    /// panel to match, and either shows or hides it.
    private func updateWindow() {
        // Compute union of all content. nil = nothing to show → hide.
        var union: CGRect? = nil
        if let lasso = currentLassoRect {
            union = lasso
        }
        for frame in selectionFrames {
            union = union.map { $0.union(frame) } ?? frame
        }

        guard let contentBox = union, !contentBox.isEmpty else {
            panel?.orderOut(nil)
            return
        }

        // Pad for stroke widths (2pt highlight border, 1.5pt lasso
        // border, plus a safety pixel).
        let panelFrame = contentBox.insetBy(dx: -5, dy: -5)

        if panel == nil {
            createPanel(initialFrame: panelFrame)
        } else {
            panel?.setFrame(panelFrame, display: false)
            view?.frame = NSRect(origin: .zero, size: panelFrame.size)
        }

        view?.windowOriginInScreenCoords = panelFrame.origin
        view?.lassoRect = currentLassoRect
        view?.selectionFrames = selectionFrames
        view?.needsDisplay = true
        panel?.orderFrontRegardless()
    }

    private func createPanel(initialFrame: CGRect) {
        let newPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        // Stationary so the panel doesn't slide between Spaces; ignoresCycle
        // so it doesn't show up in Cmd-Tab; fullScreenAuxiliary lets it
        // coexist with full-screen apps without forcing a Space change.
        newPanel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        newPanel.sharingType = .none

        let newView = OverlayView(
            frame: NSRect(origin: .zero, size: initialFrame.size)
        )
        newView.windowOriginInScreenCoords = initialFrame.origin
        newPanel.contentView = newView

        panel = newPanel
        view = newView
    }
}

// MARK: - Drawing view

private final class OverlayView: NSView {

    /// Origin of the panel's frame in Cocoa global coords. Used to
    /// convert global-coord rects (the lasso/selection content) to
    /// the view's local coord space when drawing.
    var windowOriginInScreenCoords: CGPoint = .zero

    var lassoRect: CGRect?
    var selectionFrames: [CGRect] = []

    override var isFlipped: Bool { false }

    /// Approximate corner radius of macOS system windows (Big Sur+).
    /// Browser and most native app windows use ~10pt; matching this
    /// makes the highlight feel native rather than mechanical.
    private let windowCornerRadius: CGFloat = 10.0

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Highlight borders, drawn first so the lasso rectangle (if
        // any) layers on top. Rounded-rect bezier paths so the outlines
        // match the actual window chrome. Dashed stroke (matching the
        // lasso rubber-band's dash pattern) reinforces the "lasso
        // capture" feel — these are selected windows, not permanent
        // chrome. Very subtle fill so overlapping selections don't
        // accumulate into dense blue regions.
        let strokeColor = accent.withAlphaComponent(0.57)
        let fillColor = accent.withAlphaComponent(0.0308)  // barely there
        // Dash pattern: 6pt on, 4pt off — slightly chunkier than the
        // lasso rubber-band so it reads at a different scale on larger
        // window outlines.
        let dashPattern: [CGFloat] = [6, 4]
        let strokeWidth: CGFloat = 3.0
        let halfStroke = strokeWidth / 2
        // Total inset of the path from the reported window frame.
        // Greater than halfStroke (1.5pt) so the OUTER edge of the
        // stroke sits clearly INSIDE the window border rather than
        // straddling or extending past it. The extra `insidePadding`
        // is the visible gap between the window edge and the dashed
        // line.
        let insidePadding: CGFloat = 0.5
        let totalInset = halfStroke + insidePadding  // 2pt
        for globalFrame in selectionFrames {
            let local = globalFrame.offsetBy(
                dx: -windowOriginInScreenCoords.x,
                dy: -windowOriginInScreenCoords.y
            )
            // Symmetric inset on all four sides. Result: the dashed
            // outline is fully inside the visible window border with
            // a uniform ~0.5pt gap to the edge on every side.
            let strokeRect = local.insetBy(dx: totalInset, dy: totalInset)
            // Path corner radius reduced by halfStroke (not by
            // totalInset) so that the OUTER edge of the stroke traces
            // an arc of exactly `windowCornerRadius` (10pt) — the
            // native macOS window corner radius. This means the
            // visible curvature of the highlight corner matches the
            // window's own corner curvature exactly; the inset just
            // shifts that curve inward by `insidePadding`.
            let cornerRadius = max(0, windowCornerRadius - halfStroke)
            let path = NSBezierPath(
                roundedRect: strokeRect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            fillColor.setFill()
            path.fill()
            strokeColor.setStroke()
            path.lineWidth = strokeWidth
            path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            path.stroke()
        }

        if let global = lassoRect {
            let local = global.offsetBy(
                dx: -windowOriginInScreenCoords.x,
                dy: -windowOriginInScreenCoords.y
            )
            // The lasso rubber-band stays square-cornered to read as a
            // selection gesture (matches Finder's lasso) rather than a
            // window highlight.
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(local)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(local)
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }
}
