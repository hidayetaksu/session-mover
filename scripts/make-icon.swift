#!/usr/bin/env swift
// Draws the app icon (two overlapping rounded squares with an arrow) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs iconutil, which ships with macOS)
import AppKit

func draw(size px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Tile: the macOS icon grid leaves a margin around an 824 pt rounded square.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor(red: 0.12, green: 0.25, blue: 0.55, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.20, green: 0.42, blue: 0.86, alpha: 1).cgColor,
                                   NSColor(red: 0.09, green: 0.20, blue: 0.50, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Back square (the source), then front square (the destination) overlapping it.
    func square(_ r: CGRect, fill: NSColor, stroke: NSColor) {
        let p = CGPath(roundedRect: r, cornerWidth: 64, cornerHeight: 64, transform: nil)
        ctx.addPath(p); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(14); ctx.strokePath()
    }
    square(CGRect(x: 200, y: 400, width: 340, height: 340), fill: NSColor.white.withAlphaComponent(0.28), stroke: NSColor.white.withAlphaComponent(0.85))
    square(CGRect(x: 424, y: 284, width: 400, height: 340), fill: NSColor.white, stroke: NSColor.white)

    // Arrow from the back square into the front one.
    ctx.setStrokeColor(NSColor(red: 0.12, green: 0.27, blue: 0.62, alpha: 1).cgColor)
    ctx.setLineWidth(46); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 310, y: 454)); ctx.addLine(to: CGPoint(x: 710, y: 454)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 630, y: 534)); ctx.addLine(to: CGPoint(x: 714, y: 454)); ctx.addLine(to: CGPoint(x: 630, y: 374)); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let set = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMover-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(size: px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
