#!/usr/bin/env swift
// Generates Blip app icon at all required macOS sizes.
// Design: Dark navy gradient background with 3 colored horizontal bars (CPU/MEM/DISK)
// and a cyan radar "blip" dot with rings — matching the menu bar aesthetic.
// Background fills the full square; macOS applies its own rounded-rect mask.

import Cocoa

let brandDarkNavy = NSColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1.0)
let brandDeepBlue = NSColor(red: 0.10, green: 0.15, blue: 0.30, alpha: 1.0)
let brandCyan = NSColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1.0)
let brandCyanGlow = NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.4)

func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Background gradient: full square (macOS applies its own rounded-rect mask)
    let path = NSBezierPath(rect: rect)
    let gradient = NSGradient(
        colors: [brandDarkNavy, brandDeepBlue],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    gradient.draw(in: path, angle: -45)

    // Draw 3 horizontal monitor bars (CPU/MEM/HD style)
    let barWidth = size * 0.72
    let barHeight = size * 0.075
    let barX = size * 0.14
    let barSpacing = size * 0.135
    let barStartY = size * 0.42

    let barColors: [(NSColor, CGFloat)] = [
        (NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0), 0.65),
        (NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0), 0.45),
        (NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0), 0.30),
    ]

    for (i, (color, fillPercent)) in barColors.enumerated() {
        let y = barStartY - CGFloat(i) * barSpacing
        let bgRect = NSRect(x: barX, y: y, width: barWidth, height: barHeight)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        color.withAlphaComponent(0.2).setFill()
        bgPath.fill()

        let fillRect = NSRect(x: barX, y: y, width: barWidth * fillPercent, height: barHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        color.setFill()
        fillPath.fill()
    }

    // Draw a radar "blip" dot above bars
    let dotSize = size * 0.15
    let dotCenter = NSPoint(x: size * 0.5, y: size * 0.74)

    // Outer glow
    let glowSize = dotSize * 3
    let glowRect = NSRect(
        x: dotCenter.x - glowSize / 2,
        y: dotCenter.y - glowSize / 2,
        width: glowSize,
        height: glowSize
    )
    let glowGradient = NSGradient(
        colors: [brandCyanGlow, brandCyanGlow.withAlphaComponent(0.0)]
    )!
    glowGradient.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    // Inner dot
    let dotRect = NSRect(
        x: dotCenter.x - dotSize / 2,
        y: dotCenter.y - dotSize / 2,
        width: dotSize,
        height: dotSize
    )
    brandCyan.setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    // Subtle radar rings
    brandCyan.withAlphaComponent(0.1).setStroke()
    for i in 1...2 {
        let ringSize = dotSize * CGFloat(i) * 2.0
        let ringRect = NSRect(
            x: dotCenter.x - ringSize / 2,
            y: dotCenter.y - ringSize / 2,
            width: ringSize,
            height: ringSize
        )
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = size * 0.008
        ring.stroke()
    }

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

// Generate all required sizes for traditional macOS asset catalog
let outputDir = "Blip/Resources/Assets.xcassets/AppIcon.appiconset"

struct IconSize {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)_\(scale)x.png" }
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
    let icon = generateIcon(size: CGFloat(iconSize.pixels))
    let path = "\(outputDir)/\(iconSize.filename)"
    savePNG(icon, to: path, pixelSize: iconSize.pixels)
    print("Generated \(iconSize.filename) (\(iconSize.pixels)x\(iconSize.pixels)px)")
}

print("Done!")
