// Renders the app icon: a glassy squircle (same family as Apple Mail MCP and Panes) holding a calendar page, with a
// spark for the AI link. Drawn shapes, not system artwork, so it never looks like Apple's Calendar.
// Usage: swift Scripts/make-icon.swift <output folder> [--png FILE]   (writes AppIcon.icns; --png also a 1024 PNG)
import AppKit

let arguments = CommandLine.arguments
let folder = arguments.count > 1 && !arguments[1].hasPrefix("--") ? arguments[1] : "Resources"
let output = URL(fileURLWithPath: folder).appending(path: "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppleCalendarMCP-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let coral = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1)
let magenta = NSColor(srgbRed: 0.86, green: 0.25, blue: 0.56, alpha: 1)

/// A four-point star centred on `center`.
func spark(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let inner = radius * 0.28
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4 + .pi / 2
        let r = index.isMultiple(of: 2) ? radius : inner
        let point = NSPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the shape sits inside a 824/1024 square.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [coral, magenta])!.draw(in: shape, angle: -60)
    // Glass sheen from the top.
    NSGradient(colors: [.white.withAlphaComponent(0.35), .white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: body.insetBy(dx: body.width * 0.02, dy: body.width * 0.02),
                               xRadius: body.width * 0.21, yRadius: body.width * 0.21), angle: -90)

    let w = body.width
    // The page, slightly below centre, with a translucent page behind it.
    let page = NSRect(x: body.midX - w * 0.30, y: body.minY + w * 0.17, width: w * 0.60, height: w * 0.52)
    let corner = w * 0.07
    NSColor.white.withAlphaComponent(0.25).setFill()
    NSBezierPath(roundedRect: page.offsetBy(dx: w * 0.035, dy: w * 0.035), xRadius: corner, yRadius: corner).fill()
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: page, xRadius: corner, yRadius: corner).fill()
    // The header band in the gradient's colour.
    let band = NSRect(x: page.minX, y: page.maxY - w * 0.13, width: page.width, height: w * 0.13)
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: page, xRadius: corner, yRadius: corner).addClip()
    NSGradient(colors: [coral.withAlphaComponent(0.9), magenta.withAlphaComponent(0.9)])!.draw(in: band, angle: 0)
    NSGraphicsContext.current?.restoreGraphicsState()
    // Binder rings.
    for x in [page.minX + page.width * 0.28, page.maxX - page.width * 0.28] {
        let ring = NSRect(x: x - w * 0.022, y: band.maxY - w * 0.06, width: w * 0.044, height: w * 0.10)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: ring, xRadius: w * 0.022, yRadius: w * 0.022).fill()
    }
    // A 4 × 3 grid of days; one picked.
    let columns = 4, rows = 3
    let gridTop = band.minY - w * 0.06
    let cellW = page.width * 0.8 / CGFloat(columns)
    let cellH = (gridTop - page.minY - w * 0.05) / CGFloat(rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let center = NSPoint(x: page.minX + page.width * 0.1 + cellW * (CGFloat(column) + 0.5),
                                 y: gridTop - cellH * (CGFloat(row) + 0.5))
            let picked = row == 1 && column == 2
            let radius = picked ? w * 0.045 : w * 0.022
            (picked ? magenta : NSColor(white: 0.55, alpha: 0.55)).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    // The spark, top right, with a soft glow.
    let center = NSPoint(x: page.maxX - w * 0.02, y: page.maxY + w * 0.10)
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.8)
    glow.shadowBlurRadius = w * 0.04
    glow.set()
    NSColor.white.setFill()
    spark(center: center, radius: w * 0.11).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.85).setFill()
    spark(center: NSPoint(x: center.x - w * 0.15, y: center.y + w * 0.07), radius: w * 0.045).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
if let index = arguments.firstIndex(of: "--png"), index + 1 < arguments.count {
    try render(1024).write(to: URL(fileURLWithPath: arguments[index + 1]))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
exit(iconutil.terminationStatus)
