#!/usr/bin/env swift
//
// generate-dmg-background.swift
//
// Renders the "Drag Window Wrangler → Applications" background image
// used by scripts/release.sh when building the DMG. Output is a PNG
// checked into assets/dmg-background.png. Run whenever the design
// changes; the DMG build itself reads the checked-in PNG (does NOT
// invoke this script every release, so a Swift toolchain isn't a
// release-time dependency).
//
// Usage:
//   swift scripts/generate-dmg-background.swift assets/dmg-background.png
//
// Design notes:
//   - 640×360 window fits comfortably on any Mac display without
//     forcing the user to scroll or zoom.
//   - Off-white background (RGB 0.97) matches macOS installer aesthetic
//     and stays neutral in both Light and Dark Finder modes.
//   - Icon positions inside the mounted DMG will be set by the
//     AppleScript in release.sh to match the anchor points implied
//     by this arrow: .app icon at (140, 180), Applications symlink at
//     (500, 180). Coordinates are measured from the BOTTOM-LEFT of
//     the window in AppleScript, which matches Cocoa; the image is
//     drawn with the same origin so the visual arrow lines up under
//     the icons.
//   - Arrow drawn ONCE, in a single desaturated gray so the image
//     stays legible against both light and dark app icons.
//

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: generate-dmg-background.swift <output.png>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let width: CGFloat = 640
let height: CGFloat = 360

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Background — soft off-white.
NSColor(calibratedWhite: 0.97, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Arrow from app-icon-side to Applications-icon-side.
// Icon centers are at (140, 230) and (500, 230) in Cocoa
// coordinates from bottom (icons drawn by Finder at AppleScript
// top-left y=130, so vertical center = 360-130 = 230 in Cocoa).
// Arrow shaft sits between them at y=230, leaving ~60pt gap
// around each icon so the arrow doesn't overlap the icon glyphs.
let arrowY: CGFloat = 230
let arrowStart: CGFloat = 210
let arrowEnd: CGFloat = 430
let arrowHeadSize: CGFloat = 14

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: arrowStart, y: arrowY))
shaft.line(to: NSPoint(x: arrowEnd, y: arrowY))
shaft.lineWidth = 4
shaft.lineCapStyle = .round
NSColor(calibratedWhite: 0.55, alpha: 1.0).setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEnd - arrowHeadSize, y: arrowY - arrowHeadSize))
head.line(to: NSPoint(x: arrowEnd, y: arrowY))
head.line(to: NSPoint(x: arrowEnd - arrowHeadSize, y: arrowY + arrowHeadSize))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor(calibratedWhite: 0.55, alpha: 1.0).setStroke()
head.stroke()

// Caption below the icon row.
let caption = "Drag Window Wrangler to Applications"
let captionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1.0),
]
let captionString = NSAttributedString(string: caption, attributes: captionAttributes)
let captionSize = captionString.size()
// Caption baseline y measured from the bottom of the 640×360 window.
// Finder draws its icon labels lower than a naive geometry calculation
// suggests (the label baseline sits closer to the caption than icon-
// bottom + typical-gap predicts), so we push the caption down further
// than pure math would recommend. y=25 gives ~25pt of clearance from
// the bottom edge while still leaving visible daylight between the
// icon labels and the caption.
let captionRect = NSRect(
    x: (width - captionSize.width) / 2,
    y: 25,
    width: captionSize.width,
    height: captionSize.height
)
captionString.draw(in: captionRect)

image.unlockFocus()

// Encode as PNG.
guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Failed to encode PNG.\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath) (\(png.count) bytes)")
} catch {
    FileHandle.standardError.write(Data("Failed to write \(outputPath): \(error.localizedDescription)\n".utf8))
    exit(1)
}
