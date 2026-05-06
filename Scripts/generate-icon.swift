#!/usr/bin/env swift
// Generates Blip and BlipHelper app icons for macOS 26 xcassets format.
// macOS 26: single 1024×1024 full-bleed PNG — the system clips the shape.
// Run from the repo root: swift Scripts/generate-icon.swift

import Cocoa

// MARK: - Blip icon (bars + radar dot)

func drawBlipIcon(size: CGFloat) -> NSImage {
    let s = size
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Full-bleed square background — macOS 26 clips the icon shape itself
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.setFillColor(NSColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1).cgColor)
    ctx.fill(bgRect)

    // Subtle gradient overlay for depth (clipped to square, not rounded rect)
    let gradientColors = [
        NSColor(white: 1, alpha: 0.06).cgColor,
        NSColor(white: 0, alpha: 0.05).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradientColors,
        locations: [0, 1]
    ) {
        ctx.saveGState()
        ctx.clip(to: bgRect)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: s / 2, y: s),
            end: CGPoint(x: s / 2, y: 0),
            options: []
        )
        ctx.restoreGState()
    }

    // Bar layout
    let barHeight  = s * 0.065
    let barSpacing = s * 0.045
    let barCorner  = barHeight / 2
    let barLeftX   = s * 0.22
    let barWidth   = s * 0.56

    let totalBarsHeight = 3 * barHeight + 2 * barSpacing
    let barsStartY = (s - totalBarsHeight) / 2 + totalBarsHeight

    struct BarInfo { let fill: CGFloat; let r, g, b: CGFloat }
    let bars: [BarInfo] = [
        BarInfo(fill: 0.55, r: 0.25, g: 0.52, b: 1.0),  // CPU — blue
        BarInfo(fill: 0.72, r: 0.30, g: 0.78, b: 0.40),  // MEM — green
        BarInfo(fill: 0.40, r: 1.0,  g: 0.58, b: 0.20),  // DISK — orange
    ]

    for (i, bar) in bars.enumerated() {
        let y = barsStartY - CGFloat(i) * (barHeight + barSpacing) - barHeight

        let trackPath = CGPath(
            roundedRect: CGRect(x: barLeftX, y: y, width: barWidth, height: barHeight),
            cornerWidth: barCorner, cornerHeight: barCorner, transform: nil
        )
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 0.2).cgColor)
        ctx.addPath(trackPath); ctx.fillPath()

        let fillPath = CGPath(
            roundedRect: CGRect(x: barLeftX, y: y, width: barWidth * bar.fill, height: barHeight),
            cornerWidth: barCorner, cornerHeight: barCorner, transform: nil
        )
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1.0).cgColor)
        ctx.addPath(fillPath); ctx.fillPath()
    }

    // Radar dot with glow
    let dotRadius = s * 0.075
    let dotCenter = CGPoint(x: s * 0.5, y: s * 0.72)
    let dotRect   = CGRect(
        x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    )

    // Outer glow rings
    let cyanGlow = NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.4)
    for multiplier: CGFloat in [3.0, 2.0] {
        let ringSize = dotRadius * 2 * multiplier
        let ringRect = CGRect(
            x: dotCenter.x - ringSize / 2, y: dotCenter.y - ringSize / 2,
            width: ringSize, height: ringSize
        )
        NSGradient(colors: [cyanGlow, cyanGlow.withAlphaComponent(0.0)])!
            .draw(in: NSBezierPath(ovalIn: ringRect), relativeCenterPosition: .zero)
    }

    // Glow pass
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero, blur: s * 0.06,
        color: NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.9).cgColor
    )
    ctx.setFillColor(NSColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()

    // Crisp dot on top
    ctx.setFillColor(NSColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)

    image.unlockFocus()
    return image
}

// MARK: - BlipHelper icon (lightning bolt)

func drawHelperIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Full-bleed square background
    NSGradient(
        colors: [
            NSColor(red: 0.06, green: 0.06, blue: 0.16, alpha: 1.0),
            NSColor(red: 0.12, green: 0.10, blue: 0.28, alpha: 1.0),
        ],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!.draw(in: NSBezierPath(rect: rect), angle: -45)

    let boltColor = NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
    let boltGlow  = NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.3)

    let glowSize = size * 0.75
    NSGradient(colors: [boltGlow, boltGlow.withAlphaComponent(0.0)])!
        .draw(
            in: NSBezierPath(ovalIn: NSRect(
                x: (size - glowSize) / 2, y: (size - glowSize) / 2,
                width: glowSize, height: glowSize
            )),
            relativeCenterPosition: .zero
        )

    let bolt = NSBezierPath()
    let cx = size * 0.5
    bolt.move(to: NSPoint(x: cx - size * 0.03, y: size * 0.92))
    bolt.line(to: NSPoint(x: cx - size * 0.18, y: size * 0.55))
    bolt.line(to: NSPoint(x: cx + size * 0.03, y: size * 0.55 + size * 0.06))
    bolt.line(to: NSPoint(x: cx + size * 0.03, y: size * 0.22))
    bolt.line(to: NSPoint(x: cx + size * 0.18, y: size * 0.50))
    bolt.line(to: NSPoint(x: cx - size * 0.03, y: size * 0.44))
    bolt.close()
    boltColor.setFill()
    bolt.fill()

    let barH = size * 0.045
    let barX = size * 0.2
    let barY = size * 0.10

    NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.15).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: barX, y: barY, width: size * 0.6, height: barH),
        xRadius: barH / 2, yRadius: barH / 2
    ).fill()

    boltColor.withAlphaComponent(0.6).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: barX, y: barY, width: size * 0.6 * 0.7, height: barH),
        xRadius: barH / 2, yRadius: barH / 2
    ).fill()

    image.unlockFocus()
    return image
}

// MARK: - Save helpers

func savePNG(_ image: NSImage, to path: String) {
    let size = image.size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

func writeContentsJSON(to dir: String) {
    let contents: [String: Any] = [
        "images": [
            [
                "filename": "AppIcon.png",
                "idiom": "universal",
                "platform": "mac",
                "size": "1024x1024",
            ]
        ],
        "info": ["author": "xcode", "version": 1],
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys]
    )
    try! data.write(to: URL(fileURLWithPath: "\(dir)/Contents.json"))
}

// MARK: - Main

let blipDir   = "Blip/Resources/Assets.xcassets/AppIcon.appiconset"
let helperDir = "BlipHelper/Resources/Assets.xcassets/AppIcon.appiconset"

savePNG(drawBlipIcon(size: 1024),   to: "\(blipDir)/AppIcon.png")
writeContentsJSON(to: blipDir)
print("✓ Blip AppIcon.png → \(blipDir)")

savePNG(drawHelperIcon(size: 1024), to: "\(helperDir)/AppIcon.png")
writeContentsJSON(to: helperDir)
print("✓ BlipHelper AppIcon.png → \(helperDir)")

print("Done! Re-run XcodeGen if Contents.json changed.")
