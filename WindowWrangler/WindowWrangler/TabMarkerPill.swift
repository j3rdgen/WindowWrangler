//
//  TabMarkerPill.swift
//  Window Wrangler
//
//  Floating status pill shown while Plow Mode (Mark Duplicate Tabs) is
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
//    - Scanning:  "Plow Mode  ·  scanning Chrome tabs…  ·  Esc to end"
//    - Idle:      "Plow Mode  ·  scanned 7s ago  ·  ↻  ·  Esc to end"
//
//  The ↻ is the clickable refresh button (sends onRefreshTapped).
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

    // MARK: - Internals

    private var panel: NSPanel?
    private var contentView: PillContentView?

    private func createPanel() {
        let v = PillContentView()
        v.onRefreshTapped = { [weak self] in self?.onRefreshTapped?() }
        contentView = v

        // Dark translucent capsule — identical shape to LassoModeHint /
        // PlotModeHint so Plow reads as a sibling mode in the same
        // visual language.
        let bg = NSView(frame: v.frame)
        bg.wantsLayer = true
        if let layer = bg.layer {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            layer.cornerRadius = v.frame.height / 2
            layer.masksToBounds = true
        }
        bg.addSubview(v)
        v.frame = bg.bounds

        let p = NSPanel(
            contentRect: bg.frame,
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
        p.contentView = bg

        panel = p
    }

    private func resizePanelToFitContent() {
        guard let panel, let view = contentView else { return }
        let newSize = view.intrinsicSize()
        if abs(view.frame.width - newSize.width) < 0.5 { return }
        view.frame.size = newSize
        if let bg = panel.contentView {
            bg.frame.size = newSize
            bg.layer?.cornerRadius = newSize.height / 2
        }
        var frame = panel.frame
        frame.size = newSize
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
            accessibilityDescription: "Refresh Plow Mode (⌃⌥⌘⇧D)"
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
            label.stringValue = "Plow Mode  ·  scanning Chrome tabs…  ·  Esc to end"
            prefixUpToGlyph = ""   // no glyph in scanning state
            refreshTargetAlpha = 0
        case .idle(let secondsAgo):
            let ago: String
            if secondsAgo <= 1 { ago = "just now" }
            else { ago = "\(secondsAgo)s ago" }
            label.stringValue = "Plow Mode  ·  scanned duplicate tabs \(ago)  ·        ·  Esc to end"
            prefixUpToGlyph = "Plow Mode  ·  scanned duplicate tabs \(ago)  ·  "
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
