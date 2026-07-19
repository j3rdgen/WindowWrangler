//
//  CorralReleaseMenu.swift
//  Window Wrangler
//
//  Centered "release" menu shown on ⌃⌥⌘R (and, in M8.4, via the
//  main menu). Lists every saved Corral as a row with the corral
//  name on the left and a red × delete button on the right. Clicking
//  the row triggers `onSelect`; clicking × triggers `onDelete`. When
//  the store empties (either because the user deleted the last
//  entry, or because it started empty), the menu shows a short
//  empty-state message before auto-dismissing.
//
//  Visual family matches CorralNamePill / CorralToast — dark
//  translucent rounded pill, centered on the display containing
//  the cursor, subtle fade in / out. Escape dismisses.
//
//  Delegated design: the menu doesn't own the CorralStore. It gets
//  a snapshot list on `present(...)` and a `refresh(...)` call
//  from the orchestrator whenever the underlying data changes
//  (e.g. after a delete). This keeps the menu view-layer only.
//

import AppKit

@MainActor
final class CorralReleaseMenu {

    // MARK: - Callbacks

    /// Fires when the user clicks a corral row.
    var onSelect: ((Corral) -> Void)?

    /// Fires when the user clicks a row's × delete button.
    /// The orchestrator is responsible for calling `refresh(...)`
    /// afterwards with the updated corral list so the UI reflects
    /// the deletion.
    var onDelete: ((UUID) -> Void)?

    /// Fires when the menu dismisses without selection (Escape,
    /// click-away, or the list emptied out). The orchestrator uses
    /// this to resume mouse-event consumption and release its
    /// reference to the menu.
    var onDismiss: (() -> Void)?

    // MARK: - Layout constants

    private let panelWidth: CGFloat = 400
    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 6
    private let outerPadding: CGFloat = 12
    private let horizontalPadding: CGFloat = 16
    private let deleteButtonSize: CGFloat = 24
    private let emptyStateHeight: CGFloat = 60
    /// Height of the top strip that holds the menu-level × close
    /// button. Kept small so it doesn't dominate the panel.
    private let headerHeight: CGFloat = 30
    private let closeButtonSize: CGFloat = 22

    // MARK: - State

    private var panel: ReleasePanel?
    private var contentView: NSView?
    private var buttonTargets: [ButtonTarget] = []
    private var keyMonitor: Any?
    private var corrals: [Corral] = []
    private var didFinish: Bool = false

    // MARK: - Public API

    /// Presents the menu with the given corrals. Safe to call
    /// again while showing — the existing panel is torn down and
    /// rebuilt so callers can just "re-present" on state changes
    /// without tracking whether the menu is up.
    func present(corrals: [Corral]) {
        dismiss(fireDismiss: false)
        didFinish = false
        self.corrals = corrals
        buildPanelAndShow()
        startKeyMonitor()
    }

    /// Updates the list without dismissing the panel. Used by the
    /// orchestrator after an `onDelete` completes so the deleted
    /// row disappears in place.
    ///
    /// If the list is now empty, the menu auto-dismisses via
    /// `onDismiss` after a brief empty-state flash so the user
    /// gets clear feedback that the deletion succeeded and there
    /// are no more groups.
    func refresh(corrals: [Corral]) {
        self.corrals = corrals
        rebuildContent()
        if corrals.isEmpty {
            // Give the empty-state message ~800ms of visibility
            // then dismiss the menu.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.dismiss(fireDismiss: true)
            }
        }
    }

    /// Explicit dismissal. When `fireDismiss` is true, `onDismiss`
    /// is invoked; internal auto-dismiss paths (empty-state
    /// timeout, Escape) pass true, external teardown (before a new
    /// `present(...)`) passes false.
    func dismiss(fireDismiss: Bool) {
        stopKeyMonitor()
        let willFire = fireDismiss && !didFinish
        didFinish = true
        if let panel = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        panel = nil
        contentView = nil
        buttonTargets = []
        if willFire {
            onDismiss?()
        }
    }

    // MARK: - Build

    private func buildPanelAndShow() {
        let initialSize = NSSize(width: panelWidth, height: totalContentHeight())
        let content = NSView(frame: NSRect(origin: .zero, size: initialSize))
        content.wantsLayer = true
        if let layer = content.layer {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            layer.cornerRadius = 14
            layer.masksToBounds = true
        }
        self.contentView = content

        let panel = ReleasePanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
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
        panel.contentView = content
        self.panel = panel

        rebuildContent()
        positionAtCenter(panel: panel)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Removes the current row subviews and rebuilds them from
    /// `corrals`. Also resizes the panel to match the new content
    /// height. Called from `present` and from `refresh`.
    private func rebuildContent() {
        guard let content = contentView, let panel = panel else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        buttonTargets = []

        let newSize = NSSize(width: panelWidth, height: totalContentHeight())
        content.frame = NSRect(origin: .zero, size: newSize)

        // Always-visible header × so the user has an obvious way to
        // close the menu (Escape works too via the local key monitor,
        // but a visible affordance is the UX baseline).
        addCloseButton(to: content)

        if corrals.isEmpty {
            addEmptyState(to: content)
        } else {
            addCorralRows(to: content)
        }

        var panelFrame = panel.frame
        // Keep the panel centered on its previous midpoint while it
        // grows/shrinks with the list — avoids the visual jump of
        // resizing from the origin.
        let midX = panelFrame.midX
        let midY = panelFrame.midY
        panelFrame.size = newSize
        panelFrame.origin.x = midX - newSize.width / 2
        panelFrame.origin.y = midY - newSize.height / 2
        panel.setFrame(panelFrame, display: true)
    }

    /// Computed content height for the current state, including
    /// outer padding + the header strip that hosts the × close
    /// button.
    private func totalContentHeight() -> CGFloat {
        let bodyHeight: CGFloat
        if corrals.isEmpty {
            bodyHeight = emptyStateHeight
        } else {
            bodyHeight = CGFloat(corrals.count) * rowHeight
                + CGFloat(max(0, corrals.count - 1)) * rowSpacing
        }
        return headerHeight + bodyHeight + 2 * outerPadding
    }

    // MARK: - Content: header × close button

    /// Adds a circular × button at the top-right corner. Clicking it
    /// dismisses the menu the same way Escape does — `onDismiss`
    /// fires so the orchestrator resumes lasso mouse capture.
    private func addCloseButton(to container: NSView) {
        let closeButton = NSButton(frame: NSRect(
            x: container.frame.width - outerPadding - closeButtonSize,
            y: container.frame.height - outerPadding - closeButtonSize + 2,
            width: closeButtonSize,
            height: closeButtonSize
        ))
        closeButton.title = "×"
        closeButton.bezelStyle = .circular
        closeButton.isBordered = true
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        let target = ButtonTarget { [weak self] in
            self?.dismiss(fireDismiss: true)
        }
        closeButton.target = target
        closeButton.action = #selector(ButtonTarget.fire(_:))
        buttonTargets.append(target)
        container.addSubview(closeButton)
    }

    // MARK: - Content: rows

    private func addCorralRows(to container: NSView) {
        // Layout bottom-up so the first corral in the list appears
        // at the TOP of the panel (matches natural reading order).
        let totalRows = corrals.count
        for (idx, corral) in corrals.enumerated() {
            let rowIndexFromBottom = totalRows - 1 - idx
            let y = outerPadding
                + CGFloat(rowIndexFromBottom) * (rowHeight + rowSpacing)
            let row = makeRow(for: corral, y: y)
            container.addSubview(row)
        }
    }

    private func makeRow(for corral: Corral, y: CGFloat) -> NSView {
        let rowFrame = NSRect(
            x: outerPadding,
            y: y,
            width: panelWidth - 2 * outerPadding,
            height: rowHeight
        )
        // ReleaseRowView handles `mouseDown` directly and fires
        // `onClick`. Cleaner than layering a transparent NSButton
        // under a label — NSTextField intercepts mouseDown by
        // default (even when isSelectable=false) which blocked
        // clicks from reaching the underlying button.
        let rowView = ReleaseRowView(frame: rowFrame)
        rowView.wantsLayer = true
        if let layer = rowView.layer {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer.cornerRadius = 8
        }
        rowView.onClick = { [weak self] in
            guard let self else { return }
            self.didFinish = true
            self.stopKeyMonitor()
            // Order out immediately (no fade) — same reason as the
            // name pill: whatever comes next (a success toast, an
            // alert about missing windows) needs a clear stage.
            self.panel?.orderOut(nil)
            self.panel = nil
            self.contentView = nil
            self.buttonTargets = []
            self.onSelect?(corral)
        }

        // Corral name label — `ClickThroughLabel` returns nil from
        // `hitTest`, so clicks on the label's area fall through to
        // the row view's `mouseDown`.
        let label = ClickThroughLabel(labelWithString: corral.name)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        let labelHeight: CGFloat = 20
        label.frame = NSRect(
            x: horizontalPadding,
            y: (rowFrame.height - labelHeight) / 2,
            width: rowFrame.width - 2 * horizontalPadding - deleteButtonSize,
            height: labelHeight
        )
        rowView.addSubview(label)

        // Delete × button — proper NSButton, self-intercepts clicks
        // (its own mouseDown fires before the row view's).
        let deleteButton = NSButton(frame: NSRect(
            x: rowFrame.width - horizontalPadding - deleteButtonSize,
            y: (rowFrame.height - deleteButtonSize) / 2,
            width: deleteButtonSize,
            height: deleteButtonSize
        ))
        deleteButton.title = "×"
        deleteButton.bezelStyle = .circular
        deleteButton.isBordered = true
        deleteButton.font = .systemFont(ofSize: 14, weight: .bold)
        deleteButton.contentTintColor = NSColor(
            calibratedRed: 1.0,
            green: 0.45,
            blue: 0.45,
            alpha: 1.0
        )
        let corralID = corral.id
        let deleteTarget = ButtonTarget { [weak self] in
            self?.onDelete?(corralID)
        }
        deleteButton.target = deleteTarget
        deleteButton.action = #selector(ButtonTarget.fire(_:))
        buttonTargets.append(deleteTarget)
        rowView.addSubview(deleteButton)

        return rowView
    }

    // MARK: - Content: empty state

    private func addEmptyState(to container: NSView) {
        let label = NSTextField(labelWithString: "No saved groups yet — save one with ⌃⌥⌘S")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.drawsBackground = false
        label.isBezeled = false
        label.alignment = .center
        label.sizeToFit()
        label.frame = NSRect(
            x: 0,
            y: outerPadding + (emptyStateHeight - label.frame.height) / 2,
            width: panelWidth,
            height: label.frame.height
        )
        container.addSubview(label)
    }

    // MARK: - Positioning

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

    // MARK: - Escape handling

    /// Local NSEvent monitor so Escape closes the menu while our
    /// app is active (which it is once the panel becomes key).
    /// Consumes Escape so it doesn't also trigger the lasso
    /// coordinator's escape handler (which would clear selection).
    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 0x35 = Escape (KeyCode.escape)
            if event.keyCode == 0x35 {
                MainActor.assumeIsolated {
                    self.dismiss(fireDismiss: true)
                }
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
    }
}

// MARK: - Panel + target helpers

/// NSPanel subclass that accepts keyboard focus — required so the
/// local Escape monitor observes key events while the menu is up.
private final class ReleasePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// @objc bridge for NSButton target/action → Swift closure. Same
/// pattern as CorralNamePill.SaveButtonTarget — keeps the closure
/// alive for the button's lifetime and dispatches on click.
private final class ButtonTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any) { action() }
}

/// Row container that handles mouseDown directly and fires
/// `onClick`. Used instead of a full-row transparent NSButton
/// underneath a label because NSTextField subviews intercept
/// mouseDown by default (even when isSelectable=false) and would
/// block clicks from reaching the button behind them. Delete
/// button subview is a proper NSButton and intercepts its own
/// clicks before this fires — AppKit delivers mouseDown to the
/// deepest hit-tested view.
private final class ReleaseRowView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// NSTextField subclass whose `hitTest` returns nil so clicks
/// on the label area fall through to whatever's underneath (in
/// our case, the parent `ReleaseRowView`'s mouseDown handler).
/// Necessary because a plain `NSTextField(labelWithString:)`
/// still returns itself from `hitTest`, blocking the row click.
private final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
