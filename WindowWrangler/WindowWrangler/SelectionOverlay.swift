//
//  SelectionOverlay.swift
//  Window Wrangler
//
//  Transparent overlay for the lasso rubber-band and selection
//  outlines. Uses ONE PERMANENT NSPanel PER DISPLAY, each pinned to
//  its display's frame — no panel ever moves or resizes during a
//  drag.
//
//  Why per-display panels: a single dynamically-resized panel that
//  crossed the display seam forced WindowServer to re-register the
//  panel with each display's compositor as its bounds transited,
//  producing a visible position-jitter on 30-40% of cross-display
//  drags. Per-display panels never transit anything — a global-coord
//  outline that straddles two displays is drawn by both panels, each
//  clipping to its own display bounds naturally.
//
//  Panels are non-activating, non-key, ignore mouse events, floating
//  level, and canJoinAllSpaces so they survive Space swipes on their
//  own display without re-registration.
//

import AppKit

private extension NSScreen {
    /// `CGDirectDisplayID` from the screen's deviceDescription. Stable
    /// per physical display even when `NSScreen.screens` reorders.
    /// Zero on failure (only if screen is disconnecting).
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
final class SelectionOverlay {

    // MARK: - State

    /// Panels keyed by CGDirectDisplayID. Populated lazily on first
    /// content update; kept alive for the app's entire lifetime and
    /// rebuilt only when the display configuration changes (monitor
    /// plugged/unplugged, resolution changed).
    private var panelByDisplay: [CGDirectDisplayID: NSPanel] = [:]
    private var viewByDisplay: [CGDirectDisplayID: OverlayView] = [:]

    /// Most recent lasso rectangle in Cocoa global coordinates.
    /// nil while no rubber-band is active.
    private var currentLassoRect: CGRect?

    /// Frames of currently-selected windows in Cocoa global coordinates.
    private var selectionFrames: [CGRect] = []

    /// Frame of the last-interacted selected window (Cocoa global
    /// coords). Nil suppresses the resize handles. Set by the
    /// coordinator whenever the selection or last-interacted window
    /// changes; cleared before any drag/resize interaction begins.
    private var frontmostFrame: CGRect?

    /// True while suspend is requested. All panels are ordered out
    /// and no updates occur. Reserved for future integration; not
    /// currently used by the coordinator.
    private var suspended = false

    /// Cascade acknowledgement-pulse rectangles in Cocoa global
    /// coordinates. Rendered with the same dashed-outline style as
    /// `selectionFrames`, but modulated by `pulseOpacity` so the pulse
    /// controller can flash ON→OFF→ON→OFF without creating and
    /// destroying panels per phase. Empty when no pulse is active.
    ///
    /// This is a purely cosmetic acknowledgement — it does NOT influence
    /// Lasso behavior, Cascade membership, or any AX operation. The
    /// underlying rectangles come from a cheap CG snapshot, not
    /// authoritative AX enumeration, so CG blind-spot apps (Notes,
    /// Podcasts, Grammarly) may not blink even though they DO cascade
    /// correctly. That cosmetic discrepancy is deliberate.
    private var pulseRects: [CGRect] = []

    /// Alpha multiplier applied to the pulse-outline stroke + fill.
    /// Toggled between 1.0 (visible) and 0.0 (invisible) by
    /// `CascadeFeedbackController` to produce the blink. Kept as a
    /// float rather than a bool so a future implementation could fade
    /// if needed — but current spec calls for a hard ON/OFF toggle.
    private var pulseOpacity: CGFloat = 1.0

    /// Set once we've subscribed to screen-parameter change
    /// notifications. Prevents duplicate subscriptions.
    private var screenChangeObserver: NSObjectProtocol?

    /// Resize-handle geometry, re-exported so LassoCoordinator's
    /// hit-test can derive the same rects as the drawing code without
    /// needing access to the private OverlayView.
    static let handleVisualRadius: CGFloat = 9
    static let handleHitRadius: CGFloat = 16

    init() {
        // Subscribe to display config changes (plug / unplug / resolution
        // change). On change, tear all panels down and let the next
        // update cycle recreate for the current NSScreen.screens.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanelsForNewScreenConfig()
            }
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func showLassoRect(_ rect: CGRect) {
        currentLassoRect = rect
        updateAllPanels()
    }

    func hideLassoRect() {
        currentLassoRect = nil
        updateAllPanels()
    }

    func setSelectionFrames(_ frames: [CGRect]) {
        selectionFrames = frames
        updateAllPanels()
    }

    /// Sets the frame whose bottom corners get the resize handles.
    /// Pass nil to hide the handles (e.g. during any drag / resize
    /// interaction, or when there is no selection).
    func setFrontmostFrame(_ frame: CGRect?) {
        frontmostFrame = frame
        updateAllPanels()
    }

    /// Atomic update of both stored overlay properties in a single
    /// panel refresh. The preview-only corner-resize drag calls this
    /// on every mouseDragged event; using the two separate setters
    /// would double the number of full-panel updates per pointer
    /// event. Both values are written before `updateAllPanels()` runs
    /// so the redraw sees a consistent state.
    func setResizePreview(
        selectionFrames: [CGRect],
        frontmostFrame: CGRect?
    ) {
        self.selectionFrames = selectionFrames
        self.frontmostFrame = frontmostFrame
        updateAllPanels()
    }

    /// Atomic update of the Cascade acknowledgement-pulse rectangles
    /// and opacity in a single panel refresh. Called by
    /// `CascadeFeedbackController` for each ON/OFF blink phase.
    ///
    /// Passing an empty `rects` array clears the pulse (panel hides on
    /// the next update cycle if no other content is present). Non-empty
    /// rects + opacity=0 keeps the panel visible but draws nothing —
    /// this is the "true OFF" phase of the blink, chosen over
    /// panel-hide/show churn to avoid `orderFrontRegardless()` /
    /// `orderOut()` thrash between phases.
    func setPulseState(rects: [CGRect], opacity: CGFloat) {
        pulseRects = rects
        pulseOpacity = max(0, min(1, opacity))
        updateAllPanels()
    }

    /// Kept for API compatibility with existing callers (stop(),
    /// escape handler). No-op in the per-display architecture — no
    /// fast-path pan state to tear down.
    func endGroupDrag() {
        // No-op.
    }

    /// Kept for API compatibility. In the per-display architecture
    /// each panel is pinned to its display's frame and marked
    /// canJoinAllSpaces, so Mission Control swipes on that display
    /// don't strand it on the previous Space. Rebuilds are only
    /// necessary on screen-parameter change, which we observe
    /// directly.
    func spaceDidChange() {
        // No-op.
    }

    // MARK: - Panel lifecycle

    /// Ensures a panel + view exist for every currently-connected
    /// screen. Idempotent — called on every update.
    private func ensurePanelsForCurrentScreens() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))
        // Add missing.
        for screen in NSScreen.screens {
            let id = screen.displayID
            if panelByDisplay[id] == nil {
                let (panel, view) = makePanel(for: screen)
                panelByDisplay[id] = panel
                viewByDisplay[id] = view
            }
        }
        // Remove stale (screen disconnected).
        for cachedID in panelByDisplay.keys where !currentIDs.contains(cachedID) {
            panelByDisplay[cachedID]?.orderOut(nil)
            panelByDisplay.removeValue(forKey: cachedID)
            viewByDisplay.removeValue(forKey: cachedID)
        }
    }

    /// Rebuild everything when the display configuration changes.
    /// Called from the screen-parameter observer.
    private func rebuildPanelsForNewScreenConfig() {
        for panel in panelByDisplay.values {
            panel.orderOut(nil)
        }
        panelByDisplay.removeAll(keepingCapacity: true)
        viewByDisplay.removeAll(keepingCapacity: true)
        updateAllPanels()
    }

    private func makePanel(for screen: NSScreen) -> (NSPanel, OverlayView) {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // canJoinAllSpaces: appears on every Space of this display,
        // so Mission Control swipes don't strand it.
        // stationary: don't slide during Mission Control transitions.
        // ignoresCycle: don't show up in Cmd-Tab.
        // fullScreenAuxiliary: coexist with full-screen apps.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.sharingType = .readOnly
        // Suppress AppKit's implicit window animations.
        panel.animationBehavior = .none

        // Pin panel to display's full frame — never moves, never
        // resizes for the lifetime of this display.
        panel.setFrame(screen.frame, display: false)

        let view = OverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        view.windowOriginInScreenCoords = screen.frame.origin
        panel.contentView = view

        return (panel, view)
    }

    // MARK: - Update

    /// Distributes current content (lasso rect + selection frames +
    /// frontmost frame) to each display's panel. Each panel only
    /// receives content that intersects its display bounds. Panels
    /// with no content this update are ordered out; panels with
    /// content are shown (idempotent — no reorder churn if already
    /// visible).
    private func updateAllPanels() {
        if suspended {
            for panel in panelByDisplay.values {
                panel.orderOut(nil)
            }
            return
        }
        ensurePanelsForCurrentScreens()
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard let panel = panelByDisplay[id],
                  let view = viewByDisplay[id] else { continue }
            let displayFrame = screen.frame

            // Filter content to what intersects this display.
            let framesForDisplay = selectionFrames.filter { $0.intersects(displayFrame) }
            let lassoForDisplay: CGRect? = {
                guard let rect = currentLassoRect, rect.intersects(displayFrame) else { return nil }
                return rect
            }()
            let frontmostForDisplay: CGRect? = {
                guard let rect = frontmostFrame, rect.intersects(displayFrame) else { return nil }
                return rect
            }()
            let pulseForDisplay = pulseRects.filter { $0.intersects(displayFrame) }
            // Panel stays visible while pulse rects exist even at
            // opacity 0 — the pulse controller wants "flash off" not
            // "orderOut / orderFront churn". Panel hides only when
            // `pulseRects` is CLEARED (blink complete), which happens
            // via the controller's final `setPulseState(rects: [], …)`.
            let hasContent = !framesForDisplay.isEmpty
                || lassoForDisplay != nil
                || frontmostForDisplay != nil
                || !pulseForDisplay.isEmpty

            view.selectionFrames = framesForDisplay
            view.lassoRect = lassoForDisplay
            view.frontmostFrame = frontmostForDisplay
            view.pulseRects = pulseForDisplay
            view.pulseOpacity = pulseOpacity
            view.needsDisplay = true

            if hasContent {
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            } else {
                if panel.isVisible {
                    panel.orderOut(nil)
                }
            }
        }
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

    /// The last-interacted window's frame (Cocoa global coords).
    /// When set, we render two circular grab handles at its bottom
    /// corners for the multi-window resize feature. Nil when no
    /// selection exists or during an active drag / resize.
    var frontmostFrame: CGRect?

    /// Cascade acknowledgement-pulse rectangles (Cocoa global coords)
    /// filtered to this display. Rendered with the same dashed-outline
    /// style as `selectionFrames`, scaled by `pulseOpacity`.
    var pulseRects: [CGRect] = []

    /// Multiplier for the pulse outline's stroke + fill alpha. 1.0 for
    /// the ON phase of the blink, 0.0 for the OFF phase.
    var pulseOpacity: CGFloat = 1.0

    static let handleVisualRadius: CGFloat = 9
    static let handleHitRadius: CGFloat = 16

    override var isFlipped: Bool { false }

    private let windowCornerRadius: CGFloat = 10.0

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Highlight borders — dashed rounded-rect outlines around each
        // selected window frame, drawn in local coords by subtracting
        // the panel's origin.
        let strokeColor = accent.withAlphaComponent(0.57)
        let fillColor = accent.withAlphaComponent(0.0308)
        let dashPattern: [CGFloat] = [6, 4]
        let strokeWidth: CGFloat = 3.0
        let halfStroke = strokeWidth / 2
        let insidePadding: CGFloat = 0.5
        let totalInset = halfStroke + insidePadding
        for globalFrame in selectionFrames {
            let local = globalFrame.offsetBy(
                dx: -windowOriginInScreenCoords.x,
                dy: -windowOriginInScreenCoords.y
            )
            let strokeRect = local.insetBy(dx: totalInset, dy: totalInset)
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

        // Cascade acknowledgement pulse — same dashed-outline style
        // as selection frames, alpha-scaled by pulseOpacity. Skip
        // entirely when opacity ≈ 0 or rects empty. Rendered BEFORE
        // the lasso rubber-band and resize handles so any concurrent
        // Lasso interaction visually dominates.
        if !pulseRects.isEmpty && pulseOpacity > 0.001 {
            let pulseStroke = accent.withAlphaComponent(0.57 * pulseOpacity)
            let pulseFill = accent.withAlphaComponent(0.0308 * pulseOpacity)
            for globalFrame in pulseRects {
                let local = globalFrame.offsetBy(
                    dx: -windowOriginInScreenCoords.x,
                    dy: -windowOriginInScreenCoords.y
                )
                let strokeRect = local.insetBy(dx: totalInset, dy: totalInset)
                let cornerRadius = max(0, windowCornerRadius - halfStroke)
                let path = NSBezierPath(
                    roundedRect: strokeRect,
                    xRadius: cornerRadius,
                    yRadius: cornerRadius
                )
                pulseFill.setFill()
                path.fill()
                pulseStroke.setStroke()
                path.lineWidth = strokeWidth
                path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
                path.stroke()
            }
        }

        if let global = lassoRect {
            let local = global.offsetBy(
                dx: -windowOriginInScreenCoords.x,
                dy: -windowOriginInScreenCoords.y
            )
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(local)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(local)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Resize handles — drawn LAST so they sit on top.
        if let frontmost = frontmostFrame {
            let localFrame = frontmost.offsetBy(
                dx: -windowOriginInScreenCoords.x,
                dy: -windowOriginInScreenCoords.y
            )
            let bl = CGPoint(x: localFrame.minX, y: localFrame.minY)
            let br = CGPoint(x: localFrame.maxX, y: localFrame.minY)
            let radius = OverlayView.handleVisualRadius
            let fill = accent
            let outline = NSColor.white.withAlphaComponent(0.9)
            let corners: [(center: CGPoint, symbolName: String)] = [
                (bl, "arrow.up.right.and.arrow.down.left"),
                (br, "arrow.up.left.and.arrow.down.right"),
            ]
            for (center, symbolName) in corners {
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let path = NSBezierPath(ovalIn: rect)
                fill.setFill()
                path.fill()
                outline.setStroke()
                path.lineWidth = 1.5
                path.stroke()

                let sizeConfig = NSImage.SymbolConfiguration(
                    pointSize: radius * 1.15,
                    weight: .bold
                )
                let colorConfig = NSImage.SymbolConfiguration(
                    paletteColors: [.white]
                )
                let combined = sizeConfig.applying(colorConfig)
                if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
                   let glyph = baseImage.withSymbolConfiguration(combined) {
                    let glyphSize = glyph.size
                    let glyphRect = NSRect(
                        x: center.x - glyphSize.width / 2,
                        y: center.y - glyphSize.height / 2,
                        width: glyphSize.width,
                        height: glyphSize.height
                    )
                    glyph.draw(
                        in: glyphRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high.rawValue]
                    )
                }
            }
        }
    }
}
