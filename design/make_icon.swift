// Generates design/AppIcon.icns: the MeetingBlitz submarine leaping over the
// water, in the app's own colours. Run: swift design/make_icon.swift
// (from the project root; needs only Command Line Tools + iconutil)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let teal = color(0x2EC7A0), dark = color(0x1D9E79), glow = color(0x8EE6C8)
let amber = color(0xF0A93B), ink = color(0x0E1220), foam = color(0xCFF5EA)

/// Draw the submarine (from SubmarineView, y-up), unit canvas 46x30, nose right.
func drawSub(_ ctx: CGContext) {
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: NSColor) {
        ctx.setFillColor(c.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }
    func ell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
        ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
    }
    // Propeller + shaft
    ctx.setStrokeColor(dark.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 9, y: 13)); ctx.addLine(to: CGPoint(x: 5.5, y: 13)); ctx.strokePath()
    ell(3.2, 8, 3.4, 10, dark)
    // Hull + tower
    rr(8, 4, 33, 18, 9, teal)
    rr(18, 20.5, 9, 7, 2.6, dark)
    // Periscope
    ctx.setStrokeColor(glow.cgColor); ctx.setLineWidth(1.5)
    ctx.move(to: CGPoint(x: 23, y: 27.4)); ctx.addLine(to: CGPoint(x: 23, y: 29.1))
    ctx.addLine(to: CGPoint(x: 26, y: 29.1)); ctx.strokePath()
    // Portholes
    ell(21.4, 10.4, 5.2, 5.2, ink); ell(22.5, 11.5, 3, 3, glow)
    ell(30, 10, 6, 6, ink); ell(31.1, 11.1, 3.8, 3.8, amber)
}

func drawIcon(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext

    // Big-Sur-style rounded square with a margin.
    let inset = 0.085 * s
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = 0.225 * rect.width
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(squircle); ctx.clip()

    // Ocean gradient background (the capsule's colours).
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x18A9B4).cgColor, color(0x0A4E58).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Water body with a wavy surface in the lower part.
    let waterY = rect.minY + 0.30 * rect.height
    let amp = 0.016 * s
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: rect.minX, y: waterY))
    var x = rect.minX
    while x <= rect.maxX {
        let t = (x - rect.minX) / rect.width
        wave.addLine(to: CGPoint(x: x, y: waterY + sin(t * .pi * 3.2) * amp))
        x += max(1, s / 200)
    }
    wave.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    wave.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    wave.closeSubpath()
    ctx.setFillColor(color(0x0C5A63, 0.85).cgColor)
    ctx.addPath(wave); ctx.fillPath()

    // Foam crest.
    ctx.setStrokeColor(foam.withAlphaComponent(0.75).cgColor)
    ctx.setLineWidth(max(1, 0.012 * s)); ctx.setLineCap(.round)
    x = rect.minX
    ctx.move(to: CGPoint(x: x, y: waterY))
    while x <= rect.maxX {
        let t = (x - rect.minX) / rect.width
        ctx.addLine(to: CGPoint(x: x, y: waterY + sin(t * .pi * 3.2) * amp))
        x += max(1, s / 200)
    }
    ctx.strokePath()

    // Splash droplets where the sub burst out.
    let burst = CGPoint(x: rect.minX + 0.34 * rect.width, y: waterY)
    let drops: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [   // dx, dy, r, alpha
        (-0.06, 0.10, 0.016, 0.9), (-0.10, 0.05, 0.011, 0.8), (0.02, 0.14, 0.013, 0.9),
        (0.09, 0.09, 0.010, 0.8), (-0.02, 0.05, 0.008, 0.7), (0.14, 0.04, 0.008, 0.6),
    ]
    for d in drops {
        ctx.setFillColor(foam.withAlphaComponent(d.3).cgColor)
        ctx.fillEllipse(in: CGRect(x: burst.x + d.0 * s - d.2 * s, y: burst.y + d.1 * s - d.2 * s,
                                   width: d.2 * 2 * s, height: d.2 * 2 * s))
    }

    // The leaping submarine, tilted nose-up, above the water.
    ctx.saveGState()
    ctx.translateBy(x: rect.minX + 0.50 * rect.width, y: rect.minY + 0.60 * rect.height)
    ctx.rotate(by: 14 * .pi / 180)
    let subScale = rect.width * 0.017     // 46-unit sub → ~78% of the width
    ctx.scaleBy(x: subScale, y: subScale)
    ctx.translateBy(x: -23, y: -15)       // centre the 46x30 unit canvas
    drawSub(ctx)
    ctx.restoreGState()

    // Soft top highlight for depth.
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.14).cgColor,
                                 NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.35), options: [])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Build the .iconset → .icns
let fm = FileManager.default
let iconset = "design/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let rep = drawIcon(px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "design/AppIcon.icns"]
task.launch(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "OK: design/AppIcon.icns" : "iconutil failed")
