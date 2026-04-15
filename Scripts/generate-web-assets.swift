#!/usr/bin/env swift
// Generates web assets (favicon, og-poster, homescreen icon) matching the Blip app icon design.
// Design: Dark rounded-rect bg, 3 colored progress bars (blue/green/orange), green glowing "blip" dot.

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
    let barsStartY = (s - totalBarsHeight) / 2 + totalBarsHeight

    struct BarInfo {
        let fill: CGFloat
        let r: CGFloat; let g: CGFloat; let b: CGFloat
    }

    let bars: [BarInfo] = [
        BarInfo(fill: 0.55, r: 0.25, g: 0.52, b: 1.0),   // CPU — blue
        BarInfo(fill: 0.72, r: 0.30, g: 0.78, b: 0.40),   // MEM — green
        BarInfo(fill: 0.40, r: 1.0,  g: 0.58, b: 0.20),   // DISK — orange
    ]

    for (i, bar) in bars.enumerated() {
        let y = barsStartY - CGFloat(i) * (barHeight + barSpacing) - barHeight

        let trackRect = CGRect(x: barLeftX, y: y, width: barWidth, height: barHeight)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil)
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 0.2).cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        let fillWidth = barWidth * bar.fill
        let fillRect = CGRect(x: barLeftX, y: y, width: fillWidth, height: barHeight)
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil)
        ctx.setFillColor(NSColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1.0).cgColor)
        ctx.addPath(fillPath)
        ctx.fillPath()
    }

    // Blip dot
    let dotRadius = s * 0.045
    let dotX = s * 0.74
    let dotY = s * 0.72
    let dotRect = CGRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.04, color: NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.8).cgColor)
    ctx.setFillColor(NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()

    ctx.setFillColor(NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1).cgColor)
    ctx.fillEllipse(in: dotRect)

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

    // Dark background
    ctx.setFillColor(NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // Ambient glow
    let glowColors = [
        NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.08).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 350, y: 400), startRadius: 0, endCenter: CGPoint(x: 350, y: 400), endRadius: 300, options: [])
    }

    // Draw the icon at left-center
    let iconSize: CGFloat = 200
    let iconImage = generateIcon(size: Int(iconSize))
    let iconRect = NSRect(x: 120, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
    iconImage.draw(in: iconRect)

    // Text: "Blip" title
    let titleFont = NSFont.systemFont(ofSize: 72, weight: .bold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor(white: 0.91, alpha: 1),
    ]
    let titleStr = NSAttributedString(string: "Blip", attributes: titleAttrs)
    titleStr.draw(at: NSPoint(x: 380, y: h / 2 + 20))

    // Subtitle
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

// Favicon (32x32)
let favicon = generateIcon(size: 32)
savePNG(favicon, to: "\(outputDir)/favicon.png")
print("Generated favicon.png (32x32)")

// Favicon ICO-compatible (16x16)
let favicon16 = generateIcon(size: 16)
savePNG(favicon16, to: "\(outputDir)/favicon-16.png")
print("Generated favicon-16.png (16x16)")

// Apple touch icon / homescreen icon (180x180)
let touchIcon = generateIcon(size: 180)
savePNG(touchIcon, to: "\(outputDir)/apple-touch-icon.png")
print("Generated apple-touch-icon.png (180x180)")

// Web app icon (192x192) — Android/PWA
let webIcon = generateIcon(size: 192)
savePNG(webIcon, to: "\(outputDir)/icon-192.png")
print("Generated icon-192.png (192x192)")

// Large icon (512x512) — PWA / sharing
let largeIcon = generateIcon(size: 512)
savePNG(largeIcon, to: "\(outputDir)/icon-512.png")
print("Generated icon-512.png (512x512)")

// OG poster (1200x630)
let poster = generateOGPoster()
savePNG(poster, to: "\(outputDir)/og-poster.png", pixelSize: NSSize(width: 1200, height: 630))
print("Generated og-poster.png (1200x630)")

print("Done! All web assets generated.")
