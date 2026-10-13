//
//  TabMarkerPill.swift
//  Window Wrangler
//
//  Floating status pill shown while Declutter Mode (Mark Duplicate Tabs) is
//  active. Mirrors the LassoModeHint / PlotModeHint visual format —
//  dark translucent capsule, centered under the menu bar on the screen
//  the cursor is on — so Plow reads as a system-level "you're in a
//  mode" surface, not app chrome.
//
//  Unlike the Lasso / Plot pills (pure feedback, click-through), this
//  pill has a clickable refresh glyph. Everything OUTSIDE that single
//  hit-circle still passes clicks through, so the pill never blocks
//  interaction with Chrome underneath.
//
//  Content:
//    - Scanning:  "Declutter Mode  ·  scanning Chrome tabs…  ·  Esc to end"
//    - Idle:      "Declutter Mode  ·  scanned 7s ago  ·  ↻  ·  Esc to end"
//
//  The ↻ is the clickable refresh button (sends onRefreshTapped).
//
//  Scan feedback: a continuous (NOT dashed) blue outline — same
//  accent color as the Lasso selection — pulses in intensity around
//  the pill while a scan is in progress. Driven by `setScanning`.
//

import AppKit

@MainActor
final class TabMarkerPill {

    // MARK: - Public API

    /// Invoked when the user clicks the pill's refresh glyph.
    var onRefreshTapped: (() -> Void)?

    enum State {
        case scanning
        case idle(secondsAgo: Int)
    }

    func show(initialState: State) {
        if panel == nil { createPanel() }
        update(state: initialState)
        guard let p = panel else { return }
        positionAtTopCenter(panel: p)
        p.alphaValue = 0
        p.orderFrontRegardless()
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
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
            self?.contentView = nil
            self?.rainbowView = nil
        })
    }

    func update(state: State) {
        guard let view = contentView else { return }
        view.set(state: state)
        resizePanelToFitContent()
        if let p = panel {
            positionAtTopCenter(panel: p)
        }
    }

    /// Drives the pulsing blue outline around the pill. Call every
    /// frame while a scan is in progress with the animation phase
    /// (0..1 loop); call once with `scanning: false` when the scan
    /// completes to hide the outline.
    func setScanning(_ scanning: Bool, phase: CGFloat = 0) {
        guard let outline = rainbowView else { return }
        outline.isActive = scanning
        outline.phase = phase
        outline.needsDisplay = true
    }

    // MARK: - Internals

    private var panel: NSPanel?
    private var contentView: PillContentView?
    private var rainbowView: PulseOutlineView?
    private var capsuleBg: NSView?

    /// Margin reserved around the capsule for the pulsing outline, in
    /// points. Panel grows by 2 × outlineMargin in both dimensions to
    /// make room for the stroke to sit outside the capsule edge.
    private static let outlineMargin: CGFloat = 4

    private func createPanel() {
        let v = PillContentView()
        v.onRefreshTapped = { [weak self] in self?.onRefreshTapped?() }
        contentView = v

        let capsuleWidth = v.frame.width
        let capsuleHeight = v.frame.height
        let margin = Self.outlineMargin
        let totalWidth = capsuleWidth + 2 * margin
        let totalHeight = capsuleHeight + 2 * margin

        // Dark translucent capsule — identical shape to LassoModeHint /
        // PlotModeHint so Declutter reads as a sibling mode in the same
        // visual language. Inset by `margin` on all sides from the root
        // so the pulsing outline can sit just outside its edge without
        // being clipped.
        let bg = NSView(frame: NSRect(
            x: margin, y: margin, width: capsuleWidth, height: capsuleHeight
        ))
        bg.wantsLayer = true
        if let layer = bg.layer {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            layer.cornerRadius = capsuleHeight / 2
            layer.masksToBounds = true
        }
        bg.addSubview(v)
        v.frame = bg.bounds

        // Pulsing outline — continuous (NOT dashed) blue stroke that
        // traces a rounded rect just outside the capsule edge. Alpha
        // pulses with phase while a scan is in progress; invisible
        // otherwise. Occupies the full root bounds so the stroke lands
        // in the margin area, outside the capsule but inside the panel.
        let outline = PulseOutlineView(frame: NSRect(
            x: 0, y: 0, width: totalWidth, height: totalHeight
        ))
        outline.capsuleInset = margin
        outline.capsuleCornerRadius = capsuleHeight / 2
        rainbowView = outline

        // Root container — outline underneath, capsule on top so clicks
        // continue to pass through everywhere except the refresh button.
        let root = NSView(frame: NSRect(
            x: 0, y: 0, width: totalWidth, height: totalHeight
        ))
        root.addSubview(outline)
        root.addSubview(bg)
        capsuleBg = bg

        let p = NSPanel(
            contentRect: root.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Clicks pass through everywhere EXCEPT the refresh button hit
        // circle. PillContentView.hitTest enforces this.
        p.ignoresMouseEvents = false
        p.level = NSWindow.Level(
            rawValue: NSWindow.Level.floating.rawValue + 1
        )
        p.hidesOnDeactivate = false
        p.collectionBehavior = [
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
        ]
        p.sharingType = .readOnly
        p.contentView = root

        panel = p
    }

    private func resizePanelToFitContent() {
        guard let panel, let view = contentView else { return }
        let newSize = view.intrinsicSize()
        if abs(view.frame.width - newSize.width) < 0.5 { return }
        view.frame.size = newSize

        let margin = Self.outlineMargin
        let totalWidth = newSize.width + 2 * margin
        let totalHeight = newSize.height + 2 * margin

        if let bg = capsuleBg {
            bg.frame = NSRect(
                x: margin, y: margin,
                width: newSize.width, height: newSize.height
            )
            bg.layer?.cornerRadius = newSize.height / 2
        }
        if let outline = rainbowView {
            outline.frame = NSRect(
                x: 0, y: 0,
                width: totalWidth, height: totalHeight
            )
            outline.capsuleInset = margin
            outline.capsuleCornerRadius = newSize.height / 2
            outline.needsDisplay = true
        }
        if let root = panel.contentView {
            root.frame.size = NSSize(width: totalWidth, height: totalHeight)
        }
        var frame = panel.frame
        frame.size = NSSize(width: totalWidth, height: totalHeight)
        panel.setFrame(frame, display: false)
    }

    /// Centered under the menu bar on whichever screen the cursor is
    /// on. Matches LassoModeHint / PlotModeHint positioning exactly.
    private func positionAtTopCenter(panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 16
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

// MARK: - Pill content view

@MainActor
private final class PillContentView: NSView {
    var onRefreshTapped: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    // Layout constants — matched to LassoModeHint vertical padding.
    private let hPad: CGFloat = 18
    private let vPad: CGFloat = 9
    private let buttonSize: CGFloat = 22

    /// Prefix string, up to and including the dot before the glyph
    /// slot. Set in `set(state:)`; used in `layoutSubviewsManually` to
    /// compute the button's X by measuring that prefix. Empty when
    /// no glyph is shown (scanning state).
    private var prefixUpToGlyph: String = ""

    /// Target alpha for the refresh button. Drives visibility
    /// without using isHidden — the button is ALWAYS present and
    /// always laid out at its correct position, so a transition
    /// from scanning → idle doesn't produce a transient wrong-frame
    /// flash. 0 during scanning, 1 during idle.
    private var refreshTargetAlpha: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        setupSubviews()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    private func setupSubviews() {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .left
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        addSubview(label)

        refreshButton.title = ""
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh Declutter Mode (⌃⌥⌘⇧D)"
        )
        refreshButton.imagePosition = .imageOnly
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .regularSquare
        refreshButton.target = self
        refreshButton.action = #selector(didTapRefresh)
        refreshButton.contentTintColor = .white
        refreshButton.toolTip = "Refresh scan (⌃⌥⌘⇧D)"
        // Explicit initial frame so the button never exists at
        // NSZeroRect (which caused a transient glitch on the first
        // scanning→idle transition before alphaValue took over).
        refreshButton.frame = NSRect(
            x: hPad, y: vPad, width: buttonSize, height: buttonSize
        )
        refreshButton.alphaValue = 0
        addSubview(refreshButton)
    }

    @objc private func didTapRefresh() {
        onRefreshTapped?()
    }

    func set(state: TabMarkerPill.State) {
        switch state {
        case .scanning:
            label.stringValue = "Declutter Mode  ·  scanning Chrome tabs…  ·  Esc to end"
            prefixUpToGlyph = ""   // no glyph in scanning state
            refreshTargetAlpha = 0
        case .idle(let secondsAgo):
            let ago: String
            if secondsAgo <= 1 { ago = "just now" }
            else { ago = "\(secondsAgo)s ago" }
            label.stringValue = "Declutter Mode  ·  scanned duplicate tabs \(ago)  ·        ·  Esc to end"
            prefixUpToGlyph = "Declutter Mode  ·  scanned duplicate tabs \(ago)  ·  "
            refreshTargetAlpha = 1
        }
        label.sizeToFit()
        layoutSubviewsManually()
        // Apply the alpha AFTER layout has settled the button's
        // position — guarantees no visible-at-wrong-frame flash.
        refreshButton.alphaValue = refreshTargetAlpha
    }

    func intrinsicSize() -> NSSize {
        label.sizeToFit()
        let labelWidth = label.frame.width
        let totalWidth = hPad + labelWidth + hPad
        let totalHeight = label.frame.height + vPad * 2
        return NSSize(width: ceil(totalWidth), height: ceil(totalHeight))
    }

    override func layout() {
        super.layout()
        layoutSubviewsManually()
    }

    private func layoutSubviewsManually() {
        let labelY = (bounds.height - label.frame.height) / 2
        label.frame.origin = NSPoint(x: hPad, y: labelY)

        // Position the refresh button regardless of visibility —
        // keeps the frame correct across state transitions and view
        // resizes. Position is derived from the measured prefix width,
        // so it overlays the "        " empty slot in the label.
        if !prefixUpToGlyph.isEmpty {
            let font = label.font ?? .systemFont(ofSize: 13, weight: .medium)
            let beforeSize = (prefixUpToGlyph as NSString).size(
                withAttributes: [.font: font]
            )
            let glyphX = hPad + beforeSize.width
            let glyphY = (bounds.height - buttonSize) / 2
            refreshButton.frame = NSRect(
                x: glyphX, y: glyphY, width: buttonSize, height: buttonSize
            )
        }
    }

    // Pass clicks through everywhere EXCEPT the refresh button's hit
    // area WHEN it's visible. Button is treated as not-hittable while
    // alpha=0 (scanning state), so clicks go straight through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if refreshButton.alphaValue > 0.01 {
            let hit = convert(point, from: superview)
            if refreshButton.frame.insetBy(dx: -4, dy: -4).contains(hit) {
                return refreshButton
            }
        }
        return nil
    }
}

// MARK: - Pulsing outline view

/// Continuous (NOT dashed) blue stroke that traces the pill's capsule
/// just outside its edge, pulsing in intensity while a scan is in
/// progress. Same accent color (`NSColor.controlAccentColor`) as the
/// Lasso selection outlines, but without the dash pattern so Declutter
/// reads as a distinct scanning mode. Draws nothing when inactive.
@MainActor
private final class PulseOutlineView: NSView {
    var isActive: Bool = false
    var phase: CGFloat = 0
    /// Inset from the view's edge to the capsule's edge, in points.
    /// The stroke sits midway inside this margin.
    var capsuleInset: CGFloat = 4
    /// Corner radius of the capsule being outlined — matches the
    /// pill's `cornerRadius` (height / 2).
    var capsuleCornerRadius: CGFloat = 16

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isActive, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Pulse intensity — eases up and down over `phase` (0..1 loop).
        // sin(π·phase) hits 0 at the loop boundaries and 1 at the
        // midpoint, giving a smooth breathe rather than a sawtooth.
        let intensity = 0.35 + 0.65 * sin(phase * .pi)
        let clamped = max(0.0, min(1.0, intensity))

        let strokeWidth: CGFloat = 2
        // Trace a rounded rect just outside the capsule's edge. The
        // path's radius expands by half the inset so the outline reads
        // as parallel to the capsule's curve, not pinched at the ends.
        let outset = (capsuleInset - strokeWidth) / 2
        let traceRect = bounds.insetBy(
            dx: capsuleInset - outset - strokeWidth / 2,
            dy: capsuleInset - outset - strokeWidth / 2
        )
        let traceRadius = capsuleCornerRadius + outset + strokeWidth / 2
        let path = CGPath(
            roundedRect: traceRect,
            cornerWidth: traceRadius,
            cornerHeight: traceRadius,
            transform: nil
        )

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(strokeWidth)
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(clamped).cgColor)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
