// Draws the Playa app icon and writes Support/AppIcon.icns.
// Run from the repository root: swift Support/make-icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    // Everything below is laid out on a 1024-point canvas.
    context.scaleBy(x: size / 1024, y: size / 1024)

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { color($0.0) } as CFArray, locations: stops.map(\.1))!
    }

    // macOS icon shape: an 824-point rounded square with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1B1140))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Sky: dusk indigo at the top to a warm glow at the horizon.
    let horizon: CGFloat = 400
    context.drawLinearGradient(
        gradient([(0xFFB347, 0), (0xFF6B6B, 0.32), (0xB8418F, 0.62), (0x3A1C71, 1)]),
        start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: tile.maxY), options: []
    )

    // Sun, resting on the horizon, with the play triangle cut out of it.
    let sunCentre = CGPoint(x: 512, y: horizon + 150)
    let sunRadius: CGFloat = 215
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: horizon, width: 1024, height: 1024))
    context.drawRadialGradient(
        gradient([(0xFFF3C4, 0), (0xFFD56B, 1)]),
        startCenter: sunCentre, startRadius: 0, endCenter: sunCentre, endRadius: sunRadius, options: []
    )
    // Radial gradients fill the plane; mask back to the disc.
    context.restoreGState()
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: horizon, width: 1024, height: 1024))
    let outside = CGMutablePath()
    outside.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    outside.addEllipse(in: CGRect(x: sunCentre.x - sunRadius, y: sunCentre.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    context.addPath(outside)
    context.clip(using: .evenOdd)
    context.drawLinearGradient(
        gradient([(0xFFB347, 0), (0xFF6B6B, 0.32), (0xB8418F, 0.62), (0x3A1C71, 1)]),
        start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: tile.maxY), options: []
    )
    context.restoreGState()

    let triangle = CGMutablePath()
    let half: CGFloat = 92
    let centre = CGPoint(x: sunCentre.x + 14, y: sunCentre.y + 18)
    triangle.move(to: CGPoint(x: centre.x - half * 0.78, y: centre.y + half))
    triangle.addLine(to: CGPoint(x: centre.x - half * 0.78, y: centre.y - half))
    triangle.addLine(to: CGPoint(x: centre.x + half, y: centre.y))
    triangle.closeSubpath()
    context.addPath(triangle)
    context.setFillColor(color(0xE2553F))
    context.setLineJoin(.round)
    context.setLineWidth(26)
    context.setStrokeColor(color(0xE2553F))
    context.drawPath(using: .fillStroke)

    // Sea, with the sun's reflection and two soft wave lines.
    context.drawLinearGradient(
        gradient([(0x0B1F4B, 0), (0x16407A, 0.7), (0x2A6FA8, 1)]),
        start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: horizon), options: []
    )
    context.setFillColor(color(0xFFE3A6, 0.9))
    for (index, width) in [300.0, 210.0, 130.0].enumerated() {
        let y = horizon - 34 - CGFloat(index) * 52
        context.addPath(CGPath(roundedRect: CGRect(x: 512 - width / 2, y: y, width: width, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil))
    }
    context.fillPath()

    context.setStrokeColor(color(0xFFFFFF, 0.16))
    context.setLineWidth(12)
    context.setLineCap(.round)
    for (y, phase) in [(horizon - 205, 0.0), (horizon - 262, 0.5)] {
        let wave = CGMutablePath()
        let length: CGFloat = 170
        var x = tile.minX - length * CGFloat(phase)
        wave.move(to: CGPoint(x: x, y: y))
        while x < tile.maxX {
            wave.addQuadCurve(to: CGPoint(x: x + length / 2, y: y), control: CGPoint(x: x + length / 4, y: y + 22))
            wave.addQuadCurve(to: CGPoint(x: x + length, y: y), control: CGPoint(x: x + length * 0.75, y: y - 22))
            x += length
        }
        context.addPath(wave)
    }
    context.strokePath()
    context.restoreGState()

    NSGraphicsContext.current = nil
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Support/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
