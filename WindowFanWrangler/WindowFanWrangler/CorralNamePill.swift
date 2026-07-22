//
//  CorralNamePill.swift
//  Window Wrangler
//
//  Centered floating "pill" for typing a Corral name. Appears when
//  the user triggers save (⌃⌥⌘S or menu item), takes text input,
//  and calls back with the chosen name or a cancellation.
//
//  Visual: dark translucent capsule matching LassoModeHint's family,
//  positioned mid-screen on the display containing the cursor. A
//  single-line text field takes focus immediately, with placeholder
//  text ("Name this window group…") and a 50-character cap enforced
//  live (extra characters are truncated as typed).
//
//  Interaction: Return commits (fires onSubmit with the trimmed
//  name), Escape cancels (fires onCancel), losing focus by clicking
//  elsewhere also cancels. Never blocks the runloop — no modal
//  session — so the user can click away without freezing the app.
//
//  Why a subclassed NSPanel with `canBecomeKey = true`: borderless
//  panels don't accept keyboard focus by default. Without the
//  override, the text field would never receive keystrokes.
//

import AppKit

@MainActor
final class CorralNamePill {

    // MARK: - Callbacks

    /// Fires when the user presses Return. Argument is the trimmed
    /// non-empty name. If the user pressed Return on an empty field
    /// this is NOT called — the pill treats it as a no-op so a
    /// stray Return doesn't create a nameless corral.
    var onSubmit: ((String) -> Void)?

    /// Fires when the user presses Escape or clicks away.
    var onCancel: (() -> Void)?

    // MARK: - Config

    /// Character limit matching the M8 spec. Enforced live in
    /// `controlTextDidChange` by truncating anything past this.
    private let maxCharacters: Int = 50

    // MARK: - State

    private var panel: NamePillPanel?
    private var textField: NSTextField?
    private var delegate: TextFieldDelegate?
    private var buttonTarget: SaveButtonTarget?

    /// Guards onSubmit/onCancel against being called twice — e.g.
    /// if the user hits Return AND focus loss fires in quick
    /// succession.
    private var didFinish: Bool = false

    // MARK: - Public API

    /// Presents the pill on the display containing the cursor.
    /// Idempotent: calling again while shown replaces the existing
    /// pill with a fresh one (no leftover callbacks).
    func present() {
        dismiss(fireCancel: false)
        didFinish = false

        let field = makeTextField()
        let saveButton = makeSaveButton()
        let containerView = makeContainer(field: field, saveButton: saveButton)
        let panel = makePanel(contentView: containerView)

        self.textField = field
        self.panel = panel

        let del = TextFieldDelegate(
            maxCharacters: maxCharacters,
            onSubmit: { [weak self] text in self?.handleSubmit(text: text) },
            onCancel: { [weak self] in self?.handleCancel() }
        )
        field.delegate = del
        self.delegate = del

        // Save-button target keeps the closure alive and routes the
        // click through the same handler Return uses, so both paths
        // produce identical behavior including the immediate
        // pill-dismiss animation.
        let target = SaveButtonTarget { [weak self] in
            guard let field = self?.textField else { return }
            let trimmed = field.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.handleSubmit(text: trimmed)
        }
        saveButton.target = target
        saveButton.action = #selector(SaveButtonTarget.fire(_:))
        self.buttonTarget = target

        positionAtCenter(panel: panel)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Dismisses the pill without firing either callback. Used by
    /// external code that needs to tear down state (e.g. permission
    /// revoked mid-flow). Internal handleSubmit/handleCancel paths
    /// call this too as their final step.
    func dismiss(fireCancel: Bool) {
        let willFireCancel = fireCancel && !didFinish
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
        textField = nil
        delegate = nil
        if willFireCancel {
            onCancel?()
        }
    }

    // MARK: - Handlers

    /// On submit we tear the pill down INSTANTLY — no fade — then
    /// defer the save work by one runloop tick. Why no fade:
    ///
    /// The next thing that happens after submit is either the
    /// "Replace 'NAME'?" alert (on a name collision) or the
    /// success toast. Both appear centered on the same screen the
    /// pill was on. If the pill were still on-screen mid-fade
    /// (even at 30% alpha), it would sit on top of where the
    /// alert wants to open and intercept the click on Replace —
    /// which is exactly the symptom the user hit. `orderOut`
    /// removes the panel from the window server IMMEDIATELY, so
    /// by the time the alert appears there's nothing left to
    /// steal its clicks.
    ///
    /// The defer via `DispatchQueue.main.async` still matters —
    /// it lets the runloop drain the orderOut before we block on
    /// the ~500ms capture, so the user sees the pill vanish
    /// before we're busy.
    private func handleSubmit(text: String) {
        guard !didFinish else { return }
        didFinish = true
        let submit = onSubmit
        panel?.orderOut(nil)
        panel = nil
        textField = nil
        delegate = nil
        buttonTarget = nil
        DispatchQueue.main.async {
            submit?(text)
        }
    }

    private func handleCancel() {
        guard !didFinish else { return }
        didFinish = true
        onCancel?()
        dismiss(fireCancel: false)
    }

    // MARK: - View construction

    /// Full pill layout:
    ///
    ///    [ "Name this window group…" _______________  [Save] ]
    ///
    /// Text field on the left takes the bulk of the width, Save
    /// button pinned to the right. Both anchored to the container's
    /// vertical midpoint — the text field uses a
    /// `CenteredTextFieldCell` to keep the string vertically
    /// centered inside its bounds (default NSTextFieldCell aligns
    /// to baseline, which leaves visible whitespace above the
    /// text), and the button is positioned by its natural bezel
    /// height at the container's midpoint (`.rounded` bezel has a
    /// fixed intrinsic height of ~22pt that ignores the frame
    /// you set — so we position the frame's Y so the natural
    /// bezel sits centered).
    private func makeContainer(field: NSTextField, saveButton: NSButton) -> NSView {
        let width: CGFloat = 520
        let height: CGFloat = 56
        let hPad: CGFloat = 22
        let interGap: CGFloat = 14
        let buttonWidth: CGFloat = 76
        let buttonHeight: CGFloat = 26     // natural .rounded bezel height on modern macOS
        let fieldHeight: CGFloat = 28

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        if let layer = container.layer {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            layer.cornerRadius = height / 2
            layer.masksToBounds = true
        }

        let midY = height / 2

        field.frame = NSRect(
            x: hPad,
            y: midY - fieldHeight / 2,
            width: width - 2 * hPad - buttonWidth - interGap,
            height: fieldHeight
        )
        container.addSubview(field)

        saveButton.frame = NSRect(
            x: width - hPad - buttonWidth,
            y: midY - buttonHeight / 2,
            width: buttonWidth,
            height: buttonHeight
        )
        container.addSubview(saveButton)
        return container
    }

    /// The Save button — `.rounded` bezel style is the standard
    /// macOS action-button look. The width/height are set on the
    /// frame, but `.rounded` uses its own intrinsic height for the
    /// visible bezel; positioning centers that intrinsic size at
    /// the container midpoint.
    private func makeSaveButton() -> NSButton {
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.keyEquivalent = ""  // Return is handled by the field's
                                   // delegate; giving the button
                                   // `\r` here would fire it too and
                                   // we'd end up submitting twice.
        return button
    }

    private func makeTextField() -> NSTextField {
        let field = NSTextField()
        // Swap the default cell for one that vertically centers the
        // string inside the field's bounds. The default cell aligns
        // text to the baseline, which produces the visible offset
        // between the text and the Save button the user reported.
        let centered = CenteredTextFieldCell(textCell: "")
        centered.usesSingleLineMode = true
        centered.wraps = false
        centered.isScrollable = true
        centered.isEditable = true
        centered.isBezeled = false
        centered.drawsBackground = false
        centered.lineBreakMode = .byTruncatingTail
        field.cell = centered
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16.5, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Name this window group…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                .font: NSFont.systemFont(ofSize: 16.5, weight: .regular),
            ]
        )
        return field
    }

    private func makePanel(contentView: NSView) -> NamePillPanel {
        let panel = NamePillPanel(
            contentRect: contentView.bounds,
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
        panel.contentView = contentView
        return panel
    }

    // MARK: - Positioning

    private func positionAtCenter(panel: NSPanel) {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // Slightly above vertical center — reads better than dead
        // middle (matches macOS's own "type to search" affordance).
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

// MARK: - Key-accepting panel subclass

/// NSPanel with `.borderless` doesn't accept keyboard focus by
/// default. Overriding `canBecomeKey` (and `canBecomeMain` for
/// belt-and-suspenders) enables the text field inside to receive
/// keystrokes when `makeKeyAndOrderFront` is called.
private final class NamePillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Small `NSObject` shell that routes an NSButton click into a
/// Swift closure. NSButton needs an `@objc` target/action pair; the
/// pill's state is held on a non-@objc Swift class, so this bridge
/// keeps the closure alive and dispatches on click.
private final class SaveButtonTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any) { action() }
}

/// NSTextFieldCell that draws its interior in a rectangle vertically
/// centered inside the cell's frame. The default NSTextFieldCell
/// places text at the top of the drawing rect (aligned to the
/// baseline of the first line), which — inside a tall single-line
/// pill — leaves visible whitespace above the text. Overriding
/// `drawingRect(forBounds:)` shifts the drawing rect down by half
/// the leftover vertical space so the string sits at the actual
/// vertical center.
private final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var newRect = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        let heightDelta = newRect.height - textSize.height
        if heightDelta > 0 {
            newRect.size.height -= heightDelta
            newRect.origin.y += heightDelta / 2
        }
        return newRect
    }

    // Route the field-editor's rect through the same centering
    // adjustment as drawing, so the caret + selected text stay
    // vertically centered while the user is typing (not just when
    // the field is idle and the cell is drawing text itself).
    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

// MARK: - Text field delegate

/// Enforces the character cap live and handles Return / Escape by
/// invoking the corresponding callbacks. Separated from the pill
/// class so the pill's state doesn't need to be @objc / NSObject.
private final class TextFieldDelegate: NSObject, NSTextFieldDelegate {

    private let maxCharacters: Int
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    init(
        maxCharacters: Int,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.maxCharacters = maxCharacters
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// Truncate the field's contents to `maxCharacters` on every
    /// change. Copying/pasting a long string then trims it live
    /// rather than allowing >50 characters and blocking submit.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field.stringValue.count > maxCharacters {
            field.stringValue = String(field.stringValue.prefix(maxCharacters))
        }
    }

    /// Intercepts Return (`insertNewline:`) and Escape
    /// (`cancelOperation:`). Anything else falls through to the
    /// field editor's default handling.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let trimmed = control.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onSubmit(trimmed)
            }
            // Consumed either way — empty submits are a silent no-op
            // (better than accidentally saving an unnamed corral).
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel()
            return true
        }
        return false
    }
}
