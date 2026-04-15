#!/usr/bin/env swift
// Generates Blip app icon at all required macOS sizes.
// Design: Dark rounded-rect background with 3 colored horizontal bars (CPU/MEM/DISK)
// and a small radar "blip" dot — matching the menu bar aesthetic.

import Cocoa

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Background: dark rounded rect
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.setFillColor(NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).cgColor)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // Subtle gradient overlay for depth
    let gradientColors = [
        NSColor(white: 1, alpha: 0.06).cgColor,
        NSColor(white: 0, alpha: 0.05).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: [0, 1]) {
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])
        ctx.restoreGState()
    }

    // Bar layout parameters
    let barHeight = s * 0.065
    let barSpacing = s * 0.045
    let barCorner = barHeight / 2
    let barLeftX = s * 0.22
    let barWidth = s * 0.56

    // Three bars centered vertically
    let totalBarsHeight = 3 * barHeight + 2 * barSpacing
    let barsStartY = (s - totalBarsHeight) / 2 + totalBarsHeight // flip for CG coords

    struct BarInfo {
        let fill: CGFloat   // fill percentage
        let r: CGFloat; let g: CGFloat; let b: CGFloat  // color
    }

    let bars: [BarInfo] = [
        BarInfo(fill: 0.55, r: 0.25, g: 0.52, b: 1.0),   // CPU — blue
        BarInfo(fill: 0.72, r: 0.30, g: 0.78, b: 0.40),   // MEM — green
        BarInfo(fill: 0.40, r: 1.0,  g: 0.58, b: 0.20),   // DISK — orange
    ]

    for (i, bar) in bars.enumerated() {
        let y = barsStartY - CGFloat(i) * (barHeight + barSpacing) - barHeight

        // Track (dim background)
        let trackRect = CGRect(x: barLeftX, y: y, width: barWidth, height: barHeight)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil)
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 0.2).cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Fill
        let fillWidth = barWidth * bar.fill
        let fillRect = CGRect(x: barLeftX, y: y, width: fillWidth, height: barHeight)
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil)
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1.0).cgColor)
        ctx.addPath(fillPath)
        ctx.fillPath()
    }

    // Blip dot — a small glowing circle in the upper right area
    let dotRadius = s * 0.045
    let dotX = s * 0.74
    let dotY = s * 0.72
    let dotRect = CGRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

    // Glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.04, color: NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.8).cgColor)
    ctx.setFillColor(NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()

    // Dot again on top (crisp)
    ctx.setFillColor(NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Generate all required sizes
let outputDir = "Blip/Resources/Assets.xcassets/AppIcon.appiconset"

struct IconSize {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)@\(scale)x.png" }
}

let sizes: [IconSize] = [
    IconSize(points: 16, scale: 1),
    IconSize(points: 16, scale: 2),
    IconSize(points: 32, scale: 1),
    IconSize(points: 32, scale: 2),
    IconSize(points: 128, scale: 1),
    IconSize(points: 128, scale: 2),
    IconSize(points: 256, scale: 1),
    IconSize(points: 256, scale: 2),
    IconSize(points: 512, scale: 1),
    IconSize(points: 512, scale: 2),
]

for iconSize in sizes {
    let icon = generateIcon(size: iconSize.pixels)
    let path = "\(outputDir)/\(iconSize.filename)"
    savePNG(icon, to: path, pixelSize: iconSize.pixels)
    print("Generated \(iconSize.filename) (\(iconSize.pixels)x\(iconSize.pixels)px)")
}

// Update Contents.json
let images = sizes.map { size -> [String: String] in
    [
        "filename": size.filename,
        "idiom": "mac",
        "scale": "\(size.scale)x",
        "size": "\(size.points)x\(size.points)"
    ]
}

let contents: [String: Any] = [
    "images": images,
    "info": [
        "author": "xcode",
        "version": 1
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! jsonData.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("Updated Contents.json")
print("Done!")
