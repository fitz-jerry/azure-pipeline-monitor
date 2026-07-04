// Draws the app icon (Azure-blue squircle, white rocket, green check badge)
// and writes an AppIcon.iconset with all required sizes.
// Usage: swift MakeIcon.swift <output-dir>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let S = CGFloat(pixels)

    // Background squircle on Apple's icon grid (824/1024 with baked-in shadow).
    let inset = S * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: S * 185 / 1024, yRadius: S * 185 / 1024)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    shadow.shadowBlurRadius = S * 0.02
    shadow.set()
    color(0x0B4F9E).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: color(0x3FA9F5), ending: color(0x0057A8))!
        .draw(in: rect, angle: -70)

    // Faint diagonal motion streaks behind the rocket.
    for (offset, length, alpha) in [(-0.16, 0.16, 0.30), (-0.24, 0.11, 0.22), (-0.08, 0.09, 0.22)] {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: S * (0.42 + CGFloat(offset)), yBy: S * (0.40 + CGFloat(offset)))
        t.rotate(byDegrees: 45)
        t.concat()
        let w = S * 0.022
        let streak = NSBezierPath(roundedRect: CGRect(x: -w / 2, y: -S * CGFloat(length),
                                                      width: w, height: S * CGFloat(length)),
                                  xRadius: w / 2, yRadius: w / 2)
        NSColor.white.withAlphaComponent(CGFloat(alpha)).setFill()
        streak.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Rocket, drawn pointing up in local coords, rotated to point up-right.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: S * 0.46, yBy: S * 0.50)
    t.rotate(byDegrees: -45)
    t.concat()

    let tipY = S * 0.30, baseY = -S * 0.18, w = S * 0.105

    // Fins first so the body overlaps them.
    for side: CGFloat in [1, -1] {
        let fin = NSBezierPath()
        fin.move(to: CGPoint(x: side * w * 0.8, y: baseY + S * 0.13))
        fin.curve(to: CGPoint(x: side * (w + S * 0.075), y: baseY - S * 0.055),
                  controlPoint1: CGPoint(x: side * (w + S * 0.045), y: baseY + S * 0.08),
                  controlPoint2: CGPoint(x: side * (w + S * 0.075), y: baseY + S * 0.01))
        fin.line(to: CGPoint(x: side * w * 0.8, y: baseY - S * 0.005))
        fin.close()
        NSColor.white.setFill()
        fin.fill()
    }

    // Exhaust flame.
    let flame = NSBezierPath()
    flame.move(to: CGPoint(x: S * 0.048, y: baseY - S * 0.005))
    flame.curve(to: CGPoint(x: 0, y: baseY - S * 0.165),
                controlPoint1: CGPoint(x: S * 0.05, y: baseY - S * 0.08),
                controlPoint2: CGPoint(x: S * 0.022, y: baseY - S * 0.12))
    flame.curve(to: CGPoint(x: -S * 0.048, y: baseY - S * 0.005),
                controlPoint1: CGPoint(x: -S * 0.022, y: baseY - S * 0.12),
                controlPoint2: CGPoint(x: -S * 0.05, y: baseY - S * 0.08))
    flame.close()
    color(0xFF9F0A).setFill()
    flame.fill()
    let innerFlame = NSBezierPath()
    innerFlame.move(to: CGPoint(x: S * 0.026, y: baseY - S * 0.005))
    innerFlame.curve(to: CGPoint(x: 0, y: baseY - S * 0.10),
                     controlPoint1: CGPoint(x: S * 0.027, y: baseY - S * 0.05),
                     controlPoint2: CGPoint(x: S * 0.012, y: baseY - S * 0.075))
    innerFlame.curve(to: CGPoint(x: -S * 0.026, y: baseY - S * 0.005),
                     controlPoint1: CGPoint(x: -S * 0.012, y: baseY - S * 0.075),
                     controlPoint2: CGPoint(x: -S * 0.027, y: baseY - S * 0.05))
    innerFlame.close()
    color(0xFFD60A).setFill()
    innerFlame.fill()

    // Body.
    let body = NSBezierPath()
    body.move(to: CGPoint(x: 0, y: tipY))
    body.curve(to: CGPoint(x: w, y: 0),
               controlPoint1: CGPoint(x: w * 0.55, y: tipY * 0.75),
               controlPoint2: CGPoint(x: w, y: tipY * 0.25))
    body.line(to: CGPoint(x: w, y: baseY))
    body.curve(to: CGPoint(x: -w, y: baseY),
               controlPoint1: CGPoint(x: w * 0.5, y: baseY - S * 0.03),
               controlPoint2: CGPoint(x: -w * 0.5, y: baseY - S * 0.03))
    body.line(to: CGPoint(x: -w, y: 0))
    body.curve(to: CGPoint(x: 0, y: tipY),
               controlPoint1: CGPoint(x: -w, y: tipY * 0.25),
               controlPoint2: CGPoint(x: -w * 0.55, y: tipY * 0.75))
    NSColor.white.setFill()
    body.fill()

    // Porthole.
    let portholeRadius = S * 0.052
    let porthole = NSBezierPath(ovalIn: CGRect(x: -portholeRadius, y: S * 0.045 - portholeRadius,
                                               width: portholeRadius * 2, height: portholeRadius * 2))
    color(0x0B62B8).setFill()
    porthole.fill()
    porthole.lineWidth = S * 0.016
    color(0x8ECDF8).setStroke()
    porthole.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Green check badge, bottom-right.
    let badgeCenter = CGPoint(x: S * 0.70, y: S * 0.295)
    let badgeRadius = S * 0.135
    let badge = NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - badgeRadius,
                                            y: badgeCenter.y - badgeRadius,
                                            width: badgeRadius * 2, height: badgeRadius * 2))
    color(0x30C158).setFill()
    badge.fill()
    badge.lineWidth = S * 0.028
    NSColor.white.setStroke()
    badge.stroke()
    let check = NSBezierPath()
    check.lineWidth = S * 0.042
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: CGPoint(x: badgeCenter.x - S * 0.058, y: badgeCenter.y + S * 0.004))
    check.line(to: CGPoint(x: badgeCenter.x - S * 0.016, y: badgeCenter.y - S * 0.044))
    check.line(to: CGPoint(x: badgeCenter.x + S * 0.058, y: badgeCenter.y + S * 0.048))
    NSColor.white.setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    let rep = drawIcon(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(name)")
    }
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("Wrote \(iconset)")
