// Draws the Apple TV icon and top-shelf images into tvOS/Assets.xcassets.
// tvOS icons are layered so they shift with the remote: sky and sea at the back,
// the sun in the middle and the play triangle in front.
// Run from the repository root: swift Support/make-tv-icon.swift
import AppKit

enum Layer { case back, middle, front, flat }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { color($0.0) } as CFArray, locations: stops.map(\.1))!
}

func draw(_ layer: Layer, width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let w = CGFloat(width), h = CGFloat(height)
    let horizon = h * 0.36
    let sunRadius = h * 0.27
    let sunCentre = CGPoint(x: w / 2, y: horizon + sunRadius * 0.7)

    if layer == .back || layer == .flat {
        context.drawLinearGradient(
            gradient([(0xFFB347, 0), (0xFF6B6B, 0.32), (0xB8418F, 0.62), (0x3A1C71, 1)]),
            start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation]
        )
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
        context.drawLinearGradient(
            gradient([(0x0B1F4B, 0), (0x16407A, 0.7), (0x2A6FA8, 1)]),
            start: .zero, end: CGPoint(x: 0, y: horizon), options: []
        )
        context.setStrokeColor(color(0xFFFFFF, 0.16))
        context.setLineWidth(h * 0.013)
        context.setLineCap(.round)
        let length = h * 0.2
        for (y, phase) in [(horizon * 0.42, 0.0), (horizon * 0.2, 0.5)] {
            let wave = CGMutablePath()
            var x = -length * CGFloat(phase) - length
            wave.move(to: CGPoint(x: x, y: y))
            while x < w + length {
                wave.addQuadCurve(to: CGPoint(x: x + length / 2, y: y), control: CGPoint(x: x + length / 4, y: y + h * 0.024))
                wave.addQuadCurve(to: CGPoint(x: x + length, y: y), control: CGPoint(x: x + length * 0.75, y: y - h * 0.024))
                x += length
            }
            context.addPath(wave)
        }
        context.strokePath()
        context.restoreGState()
    }

    if layer == .middle || layer == .flat {
        // Sun: the part above the horizon only.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: horizon, width: w, height: h))
        context.addEllipse(in: CGRect(x: sunCentre.x - sunRadius, y: sunCentre.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        context.clip()
        context.drawRadialGradient(
            gradient([(0xFFF3C4, 0), (0xFFD56B, 1)]),
            startCenter: sunCentre, startRadius: 0, endCenter: sunCentre, endRadius: sunRadius, options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
        // Its reflection on the water.
        context.setFillColor(color(0xFFE3A6, 0.9))
        for (index, fraction) in [0.72, 0.5, 0.31].enumerated() {
            let barWidth = sunRadius * 2 * CGFloat(fraction)
            let barHeight = h * 0.024
            let y = horizon - h * 0.045 - CGFloat(index) * h * 0.062
            context.addPath(CGPath(
                roundedRect: CGRect(x: w / 2 - barWidth / 2, y: y, width: barWidth, height: barHeight),
                cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil
            ))
        }
        context.fillPath()
    }

    if layer == .front || layer == .flat {
        let half = sunRadius * 0.43
        let centre = CGPoint(x: sunCentre.x + half * 0.15, y: sunCentre.y + sunRadius * 0.08)
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: centre.x - half * 0.78, y: centre.y + half))
        triangle.addLine(to: CGPoint(x: centre.x - half * 0.78, y: centre.y - half))
        triangle.addLine(to: CGPoint(x: centre.x + half, y: centre.y))
        triangle.closeSubpath()
        context.addPath(triangle)
        context.setFillColor(color(0xE2553F))
        context.setStrokeColor(color(0xE2553F))
        context.setLineJoin(.round)
        context.setLineWidth(sunRadius * 0.12)
        context.drawPath(using: .fillStroke)
    }

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let catalog = URL(fileURLWithPath: "tvOS/Assets.xcassets")
let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try? fileManager.removeItem(at: catalog)

func write(_ json: Any, to directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}

let info: [String: Any] = ["author": "xcode", "version": 1]

func imageSet(at directory: URL, layer: Layer, width: Int, height: Int, scales: [Int]) throws {
    var images: [[String: String]] = []
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    for scale in scales {
        let name = scale == 1 ? "image.png" : "image@\(scale)x.png"
        try draw(layer, width: width * scale, height: height * scale).write(to: directory.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "tv", "scale": "\(scale)x"])
    }
    try write(["images": images, "info": info], to: directory)
}

func imageStack(named name: String, width: Int, height: Int, scales: [Int]) throws {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    let layers: [(String, Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
    try write(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], to: stack)
    for (layerName, layer) in layers {
        let directory = stack.appendingPathComponent("\(layerName).imagestacklayer")
        try write(["info": info], to: directory)
        try imageSet(at: directory.appendingPathComponent("Content.imageset"), layer: layer, width: width, height: height, scales: scales)
    }
}

try write(["info": info], to: catalog)
try write([
    "assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ],
    "info": info,
], to: brand)
try imageStack(named: "App Icon", width: 400, height: 240, scales: [1, 2])
try imageStack(named: "App Icon - App Store", width: 1280, height: 768, scales: [1])
try imageSet(at: brand.appendingPathComponent("Top Shelf Image.imageset"), layer: .flat, width: 1920, height: 720, scales: [1, 2])
try imageSet(at: brand.appendingPathComponent("Top Shelf Image Wide.imageset"), layer: .flat, width: 2320, height: 720, scales: [1, 2])

try draw(.flat, width: 1280, height: 768).write(to: URL(fileURLWithPath: "Support/TVIcon.png"))
print("Wrote tvOS/Assets.xcassets")
