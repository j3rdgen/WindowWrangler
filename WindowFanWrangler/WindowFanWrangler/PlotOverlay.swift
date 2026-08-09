//
//  PlotOverlay.swift
//  Window Wrangler
//
//  Rendering layer for Plot (Snap Window to Drawn Area). Uses one
//  permanent NSPanel per display, pinned to that display's frame, in
//  the same architecture as SelectionOverlay — so a cross-display
//  drag never requires a panel to transit and multi-display drawing
//  is naturally clipped.
//
//  Panels are:
//   - borderless / non-activating / non-key
//   - mouse-transparent (ignoresMouseEvents = true)
//   - floating level (below the mode-hint pill, which sits one level up)
//   - canJoinAllSpaces so Space swipes don't strand them
//   - .none sharing so screen recordings don't capture them
//
//  Plot renders four kinds of content:
//   1. Selected-window outline — dashed frame around the currently
//      selected target, persistent while in windowSelected state.
//   2. Selection pulse — brief expand-then-shrink on selection.
//   3. Plot Area preview — translucent fill + solid stroke while
//      drawing. Snapped edges get emphasized stroke.
//   4. Landing pulse — brief expand-then-shrink around the actual
//      post-commit frame, then fade.
//
//  All rects are Cocoa global (bottom-left). The per-display view
//  converts to local coords for drawing.
//

import AppKit

private extension NSScreen {
    var plotOverlayDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
final class PlotOverlay {

    // MARK: - Content

    /// Frame of the currently selected window, in Cocoa global coords.
    private var selectedFrame: CGRect?

    /// Plot Area preview rectangle in Cocoa global coords, or nil
    /// when not drawing.
    private var previewRect: CGRect?

    /// Per-edge snap state of the current preview. Snapped edges get
    /// emphasized stroke.
    private var previewSnap: PlotSnapState = .none

    /// True when the current preview meets the minimum-size threshold.
    /// Invalid rects render with a warning color.
    private var previewValid: Bool = true

    /// Animated pulse overlay (selection pulse or landing pulse). Nil
    /// when no pulse is active.
    private var pulseState: PulseState?

    /// Generation token — every pulse capture increments this, and
    /// scheduled work checks that its captured value still matches
    /// before applying. Prevents stale timers from re-showing a pulse
    /// after Plot teardown.
    private var pulseGeneration: UInt64 = 0

    // MARK: - Panels

    private var panelByDisplay: [CGDirectDisplayID: NSPanel] = [:]
    private var viewByDisplay: [CGDirectDisplayID: PlotOverlayView] = [:]

    private var screenChangeObserver: NSObjectProtocol?

    init() {
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

    /// Sets or clears the persistent selected-window outline. Pass
    /// nil to clear.
    func setSelectedFrame(_ frame: CGRect?) {
        selectedFrame = frame
        updateAllPanels()
    }

    /// Updates the live Plot Area preview. Pass nil to clear.
    func setPreview(_ rect: CGRect?, snap: PlotSnapState, isValid: Bool) {
        previewRect = rect
        previewSnap = snap
        previewValid = isValid
        updateAllPanels()
    }

    /// Fires a brief expand-then-shrink pulse around `frame` (Cocoa
    /// global coords). Used for both selection confirmation and
    /// landing feedback. Cancellable via `cancelPulse()`.
    func showPulse(around frame: CGRect, style: PulseStyle) {
        pulseGeneration &+= 1
        let generation = pulseGeneration
        let pulse = PulseState(frame: frame, style: style, generation: generation, startedAt: Date())
        pulseState = pulse
        updateAllPanels()
        // Cancel the pulse after the animation duration. If a later
        // pulse was captured (generation advanced), or teardown
        // cancelled it, this no-op — the check protects against
        // stale timers re-clearing content on top of newer state.
        DispatchQueue.main.asyncAfter(deadline: .now() + pulse.style.totalDuration) { [weak self] in
            guard let self, self.pulseGeneration == generation else { return }
            self.pulseState = nil
            self.updateAllPanels()
        }
    }

    /// Cancels any active pulse without waiting for its timer.
    /// Every teardown path calls this so a landing pulse never
    /// reappears after Plot mode has ended.
    func cancelPulse() {
        pulseGeneration &+= 1
        pulseState = nil
        updateAllPanels()
    }

    /// Clears every overlay element and orders all panels out.
    /// Called by PlotCoordinator on Escape / mode-arbitration teardown.
    func clearAll() {
        selectedFrame = nil
        previewRect = nil
        previewSnap = .none
        previewValid = true
        cancelPulse()
        for panel in panelByDisplay.values {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel lifecycle

    private func ensurePanelsForCurrentScreens() {
        let currentIDs = Set(NSScreen.screens.map(\.plotOverlayDisplayID))
        for screen in NSScreen.screens {
            let id = screen.plotOverlayDisplayID
            if panelByDisplay[id] == nil {
                let (panel, view) = makePanel(for: screen)
                panelByDisplay[id] = panel
                viewByDisplay[id] = view
            }
        }
        for cachedID in panelByDisplay.keys where !currentIDs.contains(cachedID) {
            panelByDisplay[cachedID]?.orderOut(nil)
            panelByDisplay.removeValue(forKey: cachedID)
            viewByDisplay.removeValue(forKey: cachedID)
        }
    }

    private func rebuildPanelsForNewScreenConfig() {
        for panel in panelByDisplay.values {
            panel.orderOut(nil)
        }
        panelByDisplay.removeAll(keepingCapacity: true)
        viewByDisplay.removeAll(keepingCapacity: true)
        updateAllPanels()
    }

    private func makePanel(for screen: NSScreen) -> (NSPanel, PlotOverlayView) {
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
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.sharingType = .none
        panel.animationBehavior = .none
        panel.setFrame(screen.frame, display: false)

        let view = PlotOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        view.windowOriginInScreenCoords = screen.frame.origin
        panel.contentView = view
        return (panel, view)
    }

    // MARK: - Update

    private func updateAllPanels() {
        ensurePanelsForCurrentScreens()
        for screen in NSScreen.screens {
            let id = screen.plotOverlayDisplayID
            guard let panel = panelByDisplay[id],
                  let view = viewByDisplay[id] else { continue }
            let displayFrame = screen.frame

            let selectionForDisplay: CGRect? = {
                guard let rect = selectedFrame, rect.intersects(displayFrame) else { return nil }
                return rect
            }()
            let previewForDisplay: CGRect? = {
                guard let rect = previewRect, rect.intersects(displayFrame) else { return nil }
                return rect
            }()
            let pulseForDisplay: PulseState? = {
                guard let pulse = pulseState, pulse.frame.intersects(displayFrame) else { return nil }
                return pulse
            }()
            let hasContent = selectionForDisplay != nil
                || previewForDisplay != nil
                || pulseForDisplay != nil

            view.selectedFrame = selectionForDisplay
            view.previewRect = previewForDisplay
            view.previewSnap = previewSnap
            view.previewValid = previewValid
            view.pulse = pulseForDisplay
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

// MARK: - Pulse types

enum PulseStyle {
    /// One-shot expand-then-shrink used on selection.
    case selection
    /// One-shot expand-then-shrink used after a successful landing.
    case landing

    var totalDuration: TimeInterval {
        switch self {
        case .selection: return 0.28
        case .landing:   return 0.34
        }
    }

    var expandPoints: CGFloat {
        switch self {
        case .selection: return 4
        case .landing:   return 6
        }
    }

    var strokeColor: NSColor {
        switch self {
        case .selection: return NSColor.systemBlue
        case .landing:   return NSColor.systemGreen
        }
    }
}

struct PulseState {
    let frame: CGRect
    let style: PulseStyle
    let generation: UInt64
    let startedAt: Date

    /// Eased progress 0…1. Used by the drawing view to interpolate
    /// the expand-then-shrink and alpha fade.
    func progress(now: Date) -> CGFloat {
        let dt = now.timeIntervalSince(startedAt)
        let raw = max(0, min(1, CGFloat(dt / style.totalDuration)))
        return raw
    }
}

// MARK: - Drawing view

private final class PlotOverlayView: NSView {

    /// Origin of the panel's frame in Cocoa global coords. Used to
    /// convert global-coord rects to view-local for drawing.
    var windowOriginInScreenCoords: CGPoint = .zero

    var selectedFrame: CGRect?
    var previewRect: CGRect?
    var previewSnap: PlotSnapState = .none
    var previewValid: Bool = true
    var pulse: PulseState?

    /// Timer that pumps the pulse animation while one is active.
    private var pulseTimer: Timer?

    override var isFlipped: Bool { false }  // Cocoa bottom-left, matches source coords

    override var wantsUpdateLayer: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Start/stop pulse pump based on presence of a pulse.
        restartPulseTimer()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Selection outline — dashed blue, similar to Lasso.
        if let rect = selectedFrame {
            let localRect = rect.offsetBy(dx: -windowOriginInScreenCoords.x,
                                          dy: -windowOriginInScreenCoords.y)
            drawSelectionOutline(in: localRect)
        }
        // Plot Area preview — translucent fill + solid stroke, with
        // snapped-edge emphasis.
        if let rect = previewRect {
            let localRect = rect.offsetBy(dx: -windowOriginInScreenCoords.x,
                                          dy: -windowOriginInScreenCoords.y)
            drawPreview(in: localRect, snap: previewSnap, valid: previewValid)
        }
        // Pulse — animated expand-then-shrink outline.
        if let pulse = pulse {
            let localRect = pulse.frame.offsetBy(dx: -windowOriginInScreenCoords.x,
                                                 dy: -windowOriginInScreenCoords.y)
            drawPulse(in: localRect, pulse: pulse)
            restartPulseTimer()
        } else {
            stopPulseTimer()
        }
    }

    private func drawSelectionOutline(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        let dashPattern: [CGFloat] = [6, 4]
        path.setLineDash(dashPattern, count: 2, phase: 0)
        path.stroke()
    }

    private func drawPreview(in rect: CGRect, snap: PlotSnapState, valid: Bool) {
        let fillColor: NSColor
        let strokeColor: NSColor
        if valid {
            fillColor = NSColor.systemBlue.withAlphaComponent(0.14)
            strokeColor = NSColor.systemBlue.withAlphaComponent(0.85)
        } else {
            fillColor = NSColor.systemRed.withAlphaComponent(0.10)
            strokeColor = NSColor.systemRed.withAlphaComponent(0.75)
        }

        let fillPath = NSBezierPath(rect: rect)
        fillColor.setFill()
        fillPath.fill()

        // Base stroke around the whole rect.
        let stroke = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        stroke.lineWidth = 1.5
        strokeColor.setStroke()
        stroke.stroke()

        // Snapped-edge emphasis — draw a thicker line ON that edge
        // in the same color so the user can see which sides latched.
        if valid {
            let accent = NSColor.systemBlue
            accent.setStroke()
            let emphasisWidth: CGFloat = 3.5
            if snap.west {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.line(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.lineWidth = emphasisWidth
                p.stroke()
            }
            if snap.east {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.lineWidth = emphasisWidth
                p.stroke()
            }
            if snap.south {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.line(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.lineWidth = emphasisWidth
                p.stroke()
            }
            if snap.north {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.lineWidth = emphasisWidth
                p.stroke()
            }
        }
    }

    private func drawPulse(in rect: CGRect, pulse: PulseState) {
        let p = pulse.progress(now: Date())
        // Expand from 0 to 1.0 (peak at 0.5), shrink back to 0.
        // Symmetric parabola so both halves feel identical.
        let symmetric = 1 - abs(p * 2 - 1)  // 0..1..0
        let expansion = pulse.style.expandPoints * symmetric
        let alpha = max(0, 1 - p)            // fade to zero over duration

        let expanded = rect.insetBy(dx: -expansion, dy: -expansion)
        let path = NSBezierPath(roundedRect: expanded, xRadius: 5, yRadius: 5)
        path.lineWidth = 2.5
        pulse.style.strokeColor.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func restartPulseTimer() {
        stopPulseTimer()
        guard pulse != nil, window != nil else { return }
        // ~60 fps redraw while the pulse is on screen. Cheap because
        // the panel only redraws its own tiny content region.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.pulse == nil {
                self.stopPulseTimer()
                return
            }
            self.needsDisplay = true
        }
    }

    private func stopPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
