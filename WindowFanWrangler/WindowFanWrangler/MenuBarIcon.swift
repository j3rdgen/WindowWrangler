//
//  MenuBarIcon.swift
//  Window Wrangler
//
//  Programmatic drawing of the app's "three staggered windows" icon.
//  Used by the menu bar status item (small) and the onboarding window
//  hero glyph (large). Drawn rather than shipped as an asset because:
//   - It's vector, so it's crisp at any size
//   - It's a template image (isTemplate = YES), so macOS auto-recolors
//     for light/dark menu bars without us shipping multiple assets
//   - One source of truth — changing the proportions is a code edit
//

import AppKit

enum MenuBarIcon {

    /// Returns a template NSImage suitable for an NSStatusItem's button
    /// or any other UI position. Default size (18 pt) matches the
    /// macOS menu bar slot.
    static func image(size: CGFloat = 18) -> NSImage {
        let dimension = NSSize(width: size, height: size)
        let image = NSImage(size: dimension, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, canvasSize: size)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Drawing

    /// All dimensions scale proportionally with `canvasSize` so the icon
    /// renders correctly at 18 pt (menu bar) or 56 pt (onboarding hero).
    private static func draw(in ctx: CGContext, canvasSize size: CGFloat) {
        let scale = size / 18.0

        // Single rectangle's dimensions (window aspect — wider than tall)
        let rectW: CGFloat = 11 * scale
        let rectH: CGFloat = 8  * scale
        // How far each successive rectangle peeks out from behind the next
        let offset: CGFloat = 2  * scale
        // Frame padding (we have 3 rectangles overlapping with 2 offsets)
        let marginX: CGFloat = 1.5 * scale
        let marginY: CGFloat = 3   * scale
        let strokeWidth: CGFloat = 1.25 * scale

        // Cocoa coordinates: y-up. Cascade goes down-and-to-the-left:
        // back is upper-right (highest y, highest x), front is lower-left
        // (lowest y, lowest x). Front is drawn last so it sits on top.
        let front  = CGRect(x: marginX, y: marginY,
                            width: rectW, height: rectH)
        let middle = CGRect(x: marginX + offset, y: marginY + offset,
                            width: rectW, height: rectH)
        let back   = CGRect(x: marginX + 2 * offset, y: marginY + 2 * offset,
                            width: rectW, height: rectH)

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(strokeWidth)

        // 1) Draw the back rectangle's outline first (it's the bottom layer).
        ctx.stroke(back)

        // 2) Before drawing the middle rectangle's outline, clear any pixels
        //    inside its frame (plus a half-stroke margin so the outline edges
        //    of the back rectangle don't peek through where they shouldn't).
        //    Then stroke the middle outline cleanly on top.
        ctx.setBlendMode(.clear)
        ctx.fill(middle.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2))
        ctx.setBlendMode(.normal)
        ctx.stroke(middle)

        // 3) Same pattern for the front rectangle.
        ctx.setBlendMode(.clear)
        ctx.fill(front.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2))
        ctx.setBlendMode(.normal)
        ctx.stroke(front)
    }
}
