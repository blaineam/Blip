#!/usr/bin/env swift
// Generates web assets (favicon, og-poster, homescreen icon) matching the Blip app icon design.
// Design: Dark navy gradient bg, 3 colored progress bars (blue/green/orange), cyan glowing "blip" dot with radar rings.
// Background fills the full square; no transparent corners.

import Cocoa

let brandDarkNavy = NSColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1.0)
let brandDeepBlue = NSColor(red: 0.10, green: 0.15, blue: 0.30, alpha: 1.0)
let brandCyan = NSColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1.0)
let brandCyanGlow = NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.4)

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Background gradient: full square
    let path = NSBezierPath(rect: rect)
    let gradient = NSGradient(
        colors: [brandDarkNavy, brandDeepBlue],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    gradient.draw(in: path, angle: -45)

    // Draw 3 horizontal monitor bars
    let barWidth = s * 0.72
    let barHeight = s * 0.075
    let barX = s * 0.14
    let barSpacing = s * 0.135
    let barStartY = s * 0.42

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

    // Radar "blip" dot
    let dotSize = s * 0.15
    let dotCenter = NSPoint(x: s * 0.5, y: s * 0.74)

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

    let dotRect = NSRect(
        x: dotCenter.x - dotSize / 2,
        y: dotCenter.y - dotSize / 2,
        width: dotSize,
        height: dotSize
    )
    brandCyan.setFill()
    NSBezierPath(ovalIn: dotRect).fill()

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
        ring.lineWidth = s * 0.008
        ring.stroke()
    }

    image.unlockFocus()
    return image
}

func generateOGPoster() -> NSImage {
    let w: CGFloat = 1200
    let h: CGFloat = 630
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let bgGradientColors = [
        NSColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.15, blue: 0.30, alpha: 1).cgColor,
    ] as CFArray
    if let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgGradientColors, locations: [0, 1]) {
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    let cyanGlowColors = [
        NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.08).cgColor,
        NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.0).cgColor,
    ] as CFArray
    if let cyanGlow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cyanGlowColors, locations: [0, 1]) {
        let glowCenter = CGPoint(x: w * 0.5, y: h * 0.5)
        ctx.drawRadialGradient(cyanGlow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 350, options: [])
    }

    let iconSize: CGFloat = 200
    let iconImage = generateIcon(size: Int(iconSize))
    let iconRect = NSRect(x: 120, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
    iconImage.draw(in: iconRect)

    let titleFont = NSFont.systemFont(ofSize: 72, weight: .bold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor(white: 0.91, alpha: 1),
    ]
    let titleStr = NSAttributedString(string: "Blip", attributes: titleAttrs)
    titleStr.draw(at: NSPoint(x: 380, y: h / 2 + 20))

    let subFont = NSFont.systemFont(ofSize: 24, weight: .medium)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor(white: 0.56, alpha: 1),
    ]
    let subStr = NSAttributedString(string: "A featherlight macOS system monitor", attributes: subAttrs)
    subStr.draw(at: NSPoint(x: 380, y: h / 2 - 25))

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String, pixelSize: NSSize? = nil) {
    let size = pixelSize ?? NSSize(width: image.size.width, height: image.size.height)
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
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let outputDir = "docs/assets"

let favicon = generateIcon(size: 32)
savePNG(favicon, to: "\(outputDir)/favicon.png")
print("Generated favicon.png (32x32)")

let favicon16 = generateIcon(size: 16)
savePNG(favicon16, to: "\(outputDir)/favicon-16.png")
print("Generated favicon-16.png (16x16)")

let touchIcon = generateIcon(size: 180)
savePNG(touchIcon, to: "\(outputDir)/apple-touch-icon.png")
print("Generated apple-touch-icon.png (180x180)")

let webIcon = generateIcon(size: 192)
savePNG(webIcon, to: "\(outputDir)/icon-192.png")
print("Generated icon-192.png (192x192)")

let largeIcon = generateIcon(size: 512)
savePNG(largeIcon, to: "\(outputDir)/icon-512.png")
print("Generated icon-512.png (512x512)")

let poster = generateOGPoster()
savePNG(poster, to: "\(outputDir)/og-poster.png", pixelSize: NSSize(width: 1200, height: 630))
print("Generated og-poster.png (1200x630)")

print("Done! All web assets generated.")
