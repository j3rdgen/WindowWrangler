//
//  MenuBarIcon.swift
//  Window Wrangler
//
//  Loads the "lassoed cascade" SVG and rasterizes it at the requested
//  size. The asset's viewBox has been cropped to a tight square around
//  the artwork (with the natural 2:1 content centered vertically as a
//  band), so a square output here yields a square icon that matches
//  the visual footprint of other menu bar icons.
//

import AppKit

enum MenuBarIcon {

    /// Returns a template NSImage at the requested point size,
    /// rasterized to that exact dimension so NSStatusBar uses the
    /// concrete pixel size rather than the SVG's natural viewBox.
    ///
    /// Default 31pt for the menu bar — empirically tuned over several
    /// iterations to match the visual weight of system menu bar icons
    /// despite the lassoed-cascade artwork's 2:1 aspect (which leaves
    /// the top/bottom of the square frame partially empty).
    /// 80pt for the onboarding hero.
    static func image(size: CGFloat = 31) -> NSImage {
        guard let source = NSImage(named: "WindowWranglerIcon") else {
            return fallbackImage(size: size)
        }
        let dim = NSSize(width: size, height: size)
        let result = NSImage(size: dim, flipped: false) { rect in
            source.draw(in: rect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0)
            return true
        }
        result.isTemplate = true
        return result
    }

    /// Minimal placeholder shown if the asset somehow fails to load.
    private static func fallbackImage(size: CGFloat) -> NSImage {
        let dim = NSSize(width: size, height: size)
        let image = NSImage(size: dim, flipped: false) { rect in
            NSColor.black.setStroke()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2),
                                    xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
